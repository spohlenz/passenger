#  Phusion Passenger - http://www.modrails.com/
#  Copyright (C) 2008  Phusion
#
#  Phusion Passenger is a trademark of Hongli Lai & Ninh Bui.
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; version 2 of the License.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License along
#  with this program; if not, write to the Free Software Foundation, Inc.,
#  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

require 'socket'
require 'watchcat/watchcat'
require 'passenger/utils'
require 'passenger/native_support'
module Passenger

# The request handler is the layer which connects Apache with the underlying application's
# request dispatcher (i.e. either Rails's Dispatcher class or Rack).
# The request handler's job is to process incoming HTTP requests using the
# currently loaded Ruby on Rails application. HTTP requests are forwarded
# to the request handler by the web server. HTTP responses generated by the
# RoR application are forwarded to the web server, which, in turn, sends the
# response back to the HTTP client.
#
# AbstractRequestHandler is an abstract base class for easing the implementation
# of request handlers for Rails and Rack.
#
# == Design decisions
#
# Some design decisions are made because we want to decrease system
# administrator maintenance overhead. These decisions are documented
# in this section.
#
# === Abstract namespace Unix sockets
#
# AbstractRequestHandler listens on a Unix socket for incoming requests. If possible,
# AbstractRequestHandler will try to create a Unix socket on the _abstract namespace_,
# instead of on the filesystem. If the RoR application crashes (segfault),
# or if it gets killed by SIGKILL, or if the system loses power, then there
# will be no stale socket files left on the filesystem.
# Unfortunately, abstract namespace Unix sockets are only supported by Linux.
# On systems that do not support abstract namespace Unix sockets,
# AbstractRequestHandler will automatically fallback to using regular Unix socket files.
#
# It is possible to force AbstractRequestHandler to use regular Unix socket files by
# setting the environment variable PASSENGER_NO_ABSTRACT_NAMESPACE_SOCKETS
# to 1.
#
# === Owner pipes
#
# Because only the web server communicates directly with a request handler,
# we want the request handler to exit if the web server has also exited.
# This is implemented by using a so-called _owner pipe_. The writable part
# of the pipe will be passed to the web server* via a Unix socket, and the web
# server will own that part of the pipe, while AbstractRequestHandler owns
# the readable part of the pipe. AbstractRequestHandler will continuously
# check whether the other side of the pipe has been closed. If so, then it
# knows that the web server has exited, and so the request handler will exit
# as well. This works even if the web server gets killed by SIGKILL.
#
# * It might also be passed to the ApplicationPoolServerExecutable, if the web
#   server's using ApplicationPoolServer instead of StandardApplicationPool.
#
#
# == Request format
#
# Incoming "HTTP requests" are not true HTTP requests, i.e. their binary
# representation do not conform to RFC 2616. Instead, the request format
# is based on CGI, and is similar to that of SCGI.
#
# The format consists of 3 parts:
# - A 32-bit big-endian integer, containing the size of the transformed
#   headers.
# - The transformed HTTP headers.
# - The verbatim (untransformed) HTTP request body.
#
# HTTP headers are transformed to a format that satisfies the following
# grammar:
#
#  headers ::= header*
#  header ::= name NUL value NUL
#  name ::= notnull+
#  value ::= notnull+
#  notnull ::= "\x01" | "\x02" | "\x02" | ... | "\xFF"
#  NUL = "\x00"
#
# The web server transforms the HTTP request to the aforementioned format,
# and sends it to the request handler.
class AbstractRequestHandler
	# Signal which will cause the Rails application to exit immediately.
	HARD_TERMINATION_SIGNAL = "SIGTERM"
	# Signal which will cause the Rails application to exit as soon as it's done processing a request.
	SOFT_TERMINATION_SIGNAL = "SIGUSR1"
	BACKLOG_SIZE    = 50
	MAX_HEADER_SIZE = 128 * 1024
	
	# String constants which exist to relieve Ruby's garbage collector.
	IGNORE              = 'IGNORE'              # :nodoc:
	DEFAULT             = 'DEFAULT'             # :nodoc:
	NULL                = "\0"                  # :nodoc:
	CONTENT_LENGTH      = 'CONTENT_LENGTH'      # :nodoc:
	HTTP_CONTENT_LENGTH = 'HTTP_CONTENT_LENGTH' # :nodoc:
	X_POWERED_BY        = 'X-Powered-By'        # :nodoc:
	
	# The name of the socket on which the request handler accepts
	# new connections. This is either a Unix socket filename, or
	# the name for an abstract namespace Unix socket.
	#
	# If +socket_name+ refers to an abstract namespace Unix socket,
	# then the name does _not_ contain a leading null byte.
	#
	# See also using_abstract_namespace?
	attr_reader :socket_name
	
	# Specifies the maximum allowed memory usage, in MB. If after having processed
	# a request AbstractRequestHandler detects that memory usage has risen above
	# this limit, then it will gracefully exit (that is, exit after having processed
	# all pending requests).
	#
	# A value of 0 (the default) indicates that there's no limit.
	attr_accessor :memory_limit
	
	# The number of times the main loop has iterated so far. Mostly useful
	# for unit test assertions.
	attr_reader :iterations
	
	# Number of requests processed so far. This includes requests that raised
	# exceptions.
	attr_reader :processed_requests
	
	# Create a new RequestHandler with the given owner pipe.
	# +owner_pipe+ must be the readable part of a pipe IO object.
	#
	# Additionally, the following options may be given:
	# - memory_limit: Used to set the +memory_limit+ attribute.
	def initialize(owner_pipe, options = {})
		if abstract_namespace_sockets_allowed?
			@using_abstract_namespace = create_unix_socket_on_abstract_namespace
		else
			@using_abstract_namespace = false
		end
		if !@using_abstract_namespace
			create_unix_socket_on_filesystem
		end
		@owner_pipe = owner_pipe
		@previous_signal_handlers = {}
		@main_loop_thread_lock = Mutex.new
		@main_loop_thread_cond = ConditionVariable.new
		@memory_limit = options["memory_limit"] || 0
		@iterations = 0
		@processed_requests = 0
	end
	
	# Clean up temporary stuff created by the request handler.
	#
	# If the main loop was started by #main_loop, then this method may only
	# be called after the main loop has exited.
	#
	# If the main loop was started by #start_main_loop_thread, then this method
	# may be called at any time, and it will stop the main loop thread.
	def cleanup
		if @main_loop_thread
			@main_loop_thread.raise(Interrupt.new("Cleaning up"))
			@main_loop_thread.join
		end
		if @graceful_termination_watchcat
			@graceful_termination_watchcat.close
		end
		@socket.close rescue nil
		@owner_pipe.close rescue nil
		if !using_abstract_namespace?
			File.unlink(@socket_name) rescue nil
		end
	end
	
	# Returns whether socket_name refers to an abstract namespace Unix socket.
	def using_abstract_namespace?
		return @using_abstract_namespace
	end
	
	# Check whether the main loop's currently running.
	def main_loop_running?
		return @main_loop_running
	end
	
	# Enter the request handler's main loop.
	def main_loop
		if defined?(::Passenger::AbstractRequestHandler)
			# Some applications have a model named 'Passenger'.
			# So we temporarily remove it from the global namespace
			# and restore it later.
			phusion_passenger_namespace = ::Passenger
			Object.send(:remove_const, :Passenger)
		end
		reset_signal_handlers
		begin
			@graceful_termination_pipe = IO.pipe
			@main_loop_thread_lock.synchronize do
				@main_loop_running = true
				@main_loop_thread_cond.broadcast
			end
			trap(SOFT_TERMINATION_SIGNAL) do
				@graceful_termination_pipe[1].close rescue nil
				# We have at most 30 seconds to gracefully terminate.
				@graceful_termination_watchcat ||= Watchcat.new(
						:timeout => 30,
						:signal => 9)
			end
			
			while true
				@iterations += 1
				client = accept_connection
				if client.nil?
					break
				end
				begin
					headers, input = parse_request(client)
					if headers
						info = "#{headers['SERVER_NAME']}/#{headers['REQUEST_URI']}"
						Watchcat.new(:timeout => 60, :signal => 9, :info => info) do
							process_request(headers, input, client)
						end
					end
				rescue IOError, SocketError, SystemCallError => e
					print_exception("Passenger RequestHandler", e)
				ensure
					client.close rescue nil
				end
				@processed_requests += 1
				if @memory_limit > 0 && get_memory_usage > @memory_limit
					@graceful_termination_pipe[1].close rescue nil
					# We have at most 30 seconds to gracefully terminate.
					@graceful_termination_watchcat ||= Watchcat.new(
						:timeout => 30,
						:signal => 9)
				end
			end
		rescue EOFError
			# Exit main loop.
		rescue Interrupt
			# Exit main loop.
		rescue SignalException => signal
			if signal.message != HARD_TERMINATION_SIGNAL &&
			   signal.message != SOFT_TERMINATION_SIGNAL
				raise
			end
		ensure
			@graceful_termination_pipe[0].close rescue nil
			@graceful_termination_pipe[1].close rescue nil
			revert_signal_handlers
			if phusion_passenger_namespace
				Object.send(:remove_const, :Passenger) rescue nil
				Object.const_set(:Passenger, phusion_passenger_namespace)
			end
			@main_loop_thread_lock.synchronize do
				@main_loop_running = false
				@main_loop_thread_cond.broadcast
			end
		end
	end
	
	# Start the main loop in a new thread. This thread will be stopped by #cleanup.
	def start_main_loop_thread
		@main_loop_thread = Thread.new do
			main_loop
		end
		@main_loop_thread_lock.synchronize do
			while !@main_loop_running
				@main_loop_thread_cond.wait(@main_loop_thread_lock)
			end
		end
	end

private
	include Utils

	def create_unix_socket_on_abstract_namespace
		while true
			begin
				# I have no idea why, but using base64-encoded IDs
				# don't pass the unit tests. I couldn't find the cause
				# of the problem. The system supports base64-encoded
				# names for abstract namespace unix sockets just fine.
				@socket_name = generate_random_id(:hex)
				@socket_name = @socket_name.slice(0, NativeSupport::UNIX_PATH_MAX - 2)
				fd = NativeSupport.create_unix_socket("\x00#{socket_name}", BACKLOG_SIZE)
				@socket = IO.new(fd)
				@socket.instance_eval do
					def accept
						fd = NativeSupport.accept(fileno)
						return IO.new(fd)
					end
				end
				return true
			rescue Errno::EADDRINUSE
				# Do nothing, try again with another name.
			rescue Errno::ENOENT
				# Abstract namespace sockets not supported on this system.
				return false
			end
		end
	end
	
	def create_unix_socket_on_filesystem
		done = false
		while !done
			begin
				@socket_name = "/tmp/passenger.#{generate_random_id(:base64)}"
				@socket_name = @socket_name.slice(0, NativeSupport::UNIX_PATH_MAX - 1)
				@socket = UNIXServer.new(@socket_name)
				File.chmod(0600, @socket_name)
				done = true
			rescue Errno::EADDRINUSE
				# Do nothing, try again with another name.
			end
		end
	end

	# Reset signal handlers to their default handler, and install some
	# special handlers for a few signals. The previous signal handlers
	# will be put back by calling revert_signal_handlers.
	def reset_signal_handlers
		Signal.list.each_key do |signal|
			begin
				prev_handler = trap(signal, DEFAULT)
				if prev_handler != DEFAULT
					@previous_signal_handlers[signal] = prev_handler
				end
			rescue ArgumentError
				# Signal cannot be trapped; ignore it.
			end
		end
		trap('HUP', IGNORE)
		trap('ABRT') do
			raise SignalException, "SIGABRT"
		end
	end
	
	def revert_signal_handlers
		@previous_signal_handlers.each_pair do |signal, handler|
			trap(signal, handler)
		end
	end
	
	def accept_connection
		ios = select([@socket, @owner_pipe, @graceful_termination_pipe[0]]).first
		if ios.include?(@socket)
			client = @socket.accept
			
			# The real input stream is not seekable (calling _seek_
			# or _rewind_ on it will raise an exception). But some
			# frameworks (e.g. Merb) call _rewind_ if the object
			# responds to it. So we simply undefine _seek_ and
			# _rewind_.
			client.instance_eval do
				undef seek if respond_to?(:seek)
				undef rewind if respond_to?(:rewind)
			end
			
			return client
		else
			# The other end of the owner pipe has been closed, or the
			# graceful termination pipe has been closed. This is our
			# call to gracefully terminate (after having processed all
			# incoming requests).
			return nil
		end
	end
	
	# Read the next request from the given socket, and return
	# a pair [headers, input_stream]. _headers_ is a Hash containing
	# the request headers, while _input_stream_ is an IO object for
	# reading HTTP POST data.
	#
	# Returns nil if end-of-stream was encountered.
	def parse_request(socket)
		channel = MessageChannel.new(socket)
		headers_data = channel.read_scalar(MAX_HEADER_SIZE)
		if headers_data.nil?
			return
		end
		headers = Hash[*headers_data.split(NULL)]
		headers[CONTENT_LENGTH] = headers[HTTP_CONTENT_LENGTH]
		return [headers, socket]
	rescue SecurityError => e
		STDERR.puts("*** Passenger RequestHandler: HTTP header size exceeded maximum.")
		STDERR.flush
		print_exception("Passenger RequestHandler", e)
	end
	
	# Generate a long, cryptographically secure random ID string, which
	# is also a valid filename.
	def generate_random_id(method)
		case method
		when :base64
			require 'base64' unless defined?(Base64)
			data = Base64.encode64(File.read("/dev/urandom", 64))
			data.gsub!("\n", '')
			data.gsub!("+", '')
			data.gsub!("/", '')
			data.gsub!(/==$/, '')
		when :hex
			data = File.read("/dev/urandom", 64).unpack('H*')[0]
		end
		return data
	end
	
	def abstract_namespace_sockets_allowed?
		return !ENV['PASSENGER_NO_ABSTRACT_NAMESPACE_SOCKETS'] ||
			ENV['PASSENGER_NO_ABSTRACT_NAMESPACE_SOCKETS'].empty?
	end

	def self.determine_passenger_version
		rakefile = "#{File.dirname(__FILE__)}/../../Rakefile"
		if File.exist?(rakefile)
			File.read(rakefile) =~ /^PACKAGE_VERSION = "(.*)"$/
			return $1
		else
			return File.read("/etc/passenger_version.txt")
		end
	end
	
	def self.determine_passenger_header
		header = "Phusion Passenger (mod_rails/mod_rack) #{PASSENGER_VERSION}"
		if File.exist?("#{File.dirname(__FILE__)}/../../enterprisey.txt") ||
		   File.exist?("/etc/passenger_enterprisey.txt")
			header << ", Enterprise Edition"
		end
		return header
	end

public
	PASSENGER_VERSION = determine_passenger_version
	PASSENGER_HEADER = determine_passenger_header
end

end # module Passenger
