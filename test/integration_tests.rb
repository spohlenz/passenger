require 'net/http'
require 'uri'
require 'resolv'
require 'socket'
require 'fileutils'
require 'timeout'
require 'support/config'
require 'support/test_helper'
require 'support/multipart'
require 'support/apache2_controller'
require 'passenger/platform_info'

include PlatformInfo

# TODO: test the 'RailsUserSwitching' and 'RailsDefaultUser' option.
# TODO: test custom page caching directory

shared_examples_for "MyCook(tm) beta" do
	it "is possible to fetch static assets" do
		get('/images/rails.png').should == public_file('images/rails.png')
	end
	
	it "supports page caching on non-index URIs" do
		get('/welcome/cached').should =~ %r{This is the cached version of /welcome/cached}
	end
	
	it "supports page caching on index URIs" do
		get('/uploads').should =~ %r{This is the cached version of /uploads}
	end
	
	it "doesn't use page caching if the HTTP request is not GET" do
		post('/welcome/cached').should =~ %r{This content should never be displayed}
	end
	
	it "isn't interfered by Rails's default .htaccess dispatcher rules" do
		get('/welcome/in_passenger').should == 'true'
	end
	
	it "is possible to GET a regular Rails page" do
		get('/').should =~ /Welcome to MyCook/
	end
	
	it "is possible to pass GET parameters to a Rails page" do
		result = get('/welcome/parameters_test?hello=world&recipe[name]=Green+Bananas')
		result.should =~ %r{<hello>world</hello>}
		result.should =~ %r{<recipe>}
		result.should =~ %r{<name>Green Bananas</name>}
	end
	
	it "is possible to POST to a Rails page" do
		result = post('/recipes', {
			'recipe[name]' => 'Banana Pancakes',
			'recipe[instructions]' => 'Call 0900-BANANAPANCAKES'
		})
		result.should =~ %r{HTTP method: post}
		result.should =~ %r{Name: Banana Pancakes}
		result.should =~ %r{Instructions: Call 0900-BANANAPANCAKES}
	end
	
	it "is possible to upload a file" do
		rails_png = File.open("#{@stub.app_root}/public/images/rails.png", 'rb')
		params = {
			'upload[name1]' => 'Kotonoha',
			'upload[name2]' => 'Sekai',
			'upload[data]' => rails_png
		}
		begin
			response = post('/uploads', params)
			rails_png.rewind
			response.should ==
				"name 1 = Kotonoha\n" <<
				"name 2 = Sekai\n" <<
				"data = " << rails_png.read
		ensure
			rails_png.close
		end
	end
	
	it "can properly handle custom headers" do
		response = get_response('/welcome/headers_test')
		response["X-Foo"].should == "Bar"
	end

	it "supports %2f in URIs" do
		get('/welcome/show_id/foo%2fbar').should == 'foo/bar'
	end

	it "has AbstractRequest which returns a request_uri without hostname, with query_string" do
		get('/welcome/request_uri?foo=bar%20escaped').should =~ %r{/welcome/request_uri\?foo=bar%20escaped}
	end

	it "supports restarting via restart.txt" do
		begin
			controller = "#{@stub.app_root}/app/controllers/test_controller.rb"
			restart_file = "#{@stub.app_root}/tmp/restart.txt"
			
			File.open(controller, 'w') do |f|
				f.write %q{
					class TestController < ApplicationController
						layout nil
						def index
							render :text => "foo"
						end
					end
				}
			end
			File.open(restart_file, 'w') do end
			get('/test').should == "foo"
		
			File.open(controller, 'w') do |f|
				f.write %q{
					class TestController < ApplicationController
						layout nil
						def index
							render :text => "bar"
						end
					end
				}
			end

			File.open(restart_file, 'w') do end
			get('/test').should == 'bar'
		ensure
			File.unlink(controller) rescue nil
			File.unlink(restart_file) rescue nil
		end
	end
	
	it "does not make the web server crash if the app crashes" do
		post('/welcome/terminate')
		sleep(0.25) # Give the app the time to terminate itself.
		get('/').should =~ /Welcome to MyCook/
	end
	
	it "does not conflict with Phusion Passenger if there's a model named 'Passenger'" do
		Dir.mkdir("#{@stub.app_root}/app/models") rescue nil
		File.open("#{@stub.app_root}/app/models/passenger.rb", 'w') do |f|
			f.write(%q{
				class Passenger
					def name
						return "Gourry Gabriev"
					end
				end
			})
		end
		begin
			system "touch '#{@stub.app_root}/tmp/restart.txt'"
			get('/welcome/passenger_name').should == 'Gourry Gabriev'
		ensure
			File.unlink("#{@stub.app_root}/app/models/passenger.rb") rescue nil
		end
	end
	
	if Process.uid == 0
		it "runs as an unprivileged user" do
			post('/welcome/touch')
			begin
				stat = File.stat("#{@stub.app_root}/public/touch.txt")
				stat.uid.should_not == 0
				stat.gid.should_not == 0
			ensure
				File.unlink("#{@stub.app_root}/public/touch.txt") rescue nil
			end
		end
	end
end

shared_examples_for "HelloWorld Rack application" do
	it "is possible to fetch static assets" do
		get('/rack.jpg').should == public_file('rack.jpg')
	end
	
	it "is possible to GET a regular Rack page" do
		get('/').should =~ /hello/
	end
	
	it "supports restarting via restart.txt" do
		get('/').should =~ /hello/
		File.write("#{@stub.app_root}/config.ru", %q{
			app = lambda do |env|
				[200, { "Content-Type" => "text/html" }, "changed"]
			end
			run app
		})
		File.new("#{@stub.app_root}/tmp/restart.txt", "w").close
		get('/').should == "changed"
		File.exist?("#{@stub.app_root}/tmp/restart.txt").should == false
	end
	
	if Process.uid == 0
		it "runs as an unprivileged user" do
			File.prepend("#{@stub.app_root}/config.ru", %q{
				File.new('foo.txt', 'w').close
			})
			File.new("#{@stub.app_root}/tmp/restart.txt", "w").close
			get('/')
			stat = File.stat("#{@stub.app_root}/foo.txt")
			stat.uid.should_not == 0
			stat.gid.should_not == 0
		end
	end
end

shared_examples_for "HelloWorld WSGI application" do
	after :each do
		File.unlink("#{@stub.app_root}/passenger_wsgi.pyc") rescue nil
	end
	
	it "is possible to fetch static assets" do
		get('/wsgi-snake.jpg').should == public_file('wsgi-snake.jpg')
	end
	
	it "is possible to GET a regular WSGI page" do
		get('/').should =~ /Hello World/
	end
	
	it "supports restarting via restart.txt" do
		get('/').should =~ /Hello World/
		
		code = %q{
			def application(env, start_response):
				start_response('200 OK', [('Content-Type', 'text/html')])
				return ["changed"]
		}.gsub(/^\t\t\t/, '')
		
		File.write("#{@stub.app_root}/passenger_wsgi.py", code)
		File.new("#{@stub.app_root}/tmp/restart.txt", "w").close
		get('/').should == "changed"
		File.exist?("#{@stub.app_root}/tmp/restart.txt").should == false
	end
	
	if Process.uid == 0
		it "runs as an unprivileged user" do
			File.prepend("#{@stub.app_root}/passenger_wsgi.py",
				"file('foo.txt', 'w').close()\n")
			File.new("#{@stub.app_root}/tmp/restart.txt", "w").close
			get('/')
			stat = File.stat("#{@stub.app_root}/foo.txt")
			stat.uid.should_not == 0
			stat.gid.should_not == 0
		end
	end
end

describe "mod_passenger running in Apache 2" do
	include TestHelper
	
	before :all do
		check_hosts_configuration
		@apache2 = Apache2Controller.new
		if Process.uid == 0
			@apache2.set(
				:www_user => CONFIG['normal_user_1'],
				:www_group => Etc.getgrgid(Etc.getpwnam(CONFIG['normal_user_1']).gid).name
			)
		end
	end
	
	after :all do
		@apache2.stop
	end
	
	describe ": MyCook(tm) beta running on root URI" do
		before :all do
			@server = "http://passenger.test:#{@apache2.port}"
			@stub = setup_rails_stub('mycook')
			@apache2 << "RailsMaxPoolSize 1"
			@apache2.add_vhost("passenger.test", File.expand_path("#{@stub.app_root}/public"))
			@apache2.start
		end
		
		after :all do
			@stub.destroy
		end
		
		it_should_behave_like "MyCook(tm) beta"
		
		it "doesn't block Rails while an upload is in progress" do
			get('/') # Force spawning so that the timeout below is enough.
			
			socket = TCPSocket.new('passenger.test', @apache2.port)
			begin
				socket.write("POST / HTTP/1.1\r\n")
				socket.write("Host: passenger.test\r\n")
			
				upload_data = File.read("stub/upload_data.txt")
				size_of_first_half = upload_data.size / 2
			
				socket.write(upload_data[0..size_of_first_half])
				socket.flush
				
				Timeout.timeout(10) do
					get('/').should =~ /Welcome to MyCook/
				end
			ensure
				socket.close rescue nil
			end
		end
		
		it "doesn't block Rails while a large number of uploads are in progress" do
			get('/') # Force spawning so that the timeout below is enough.
			sockets = []
			
			upload_data = File.read("stub/upload_data.txt")
			size_of_first_half = upload_data.size / 2
			
			begin
				10.times do |i|
					socket = TCPSocket.new('passenger.test', @apache2.port)
					sockets << socket
					socket.write("POST / HTTP/1.1\r\n")
					socket.write("Host: passenger.test\r\n")
					socket.write(upload_data[0..size_of_first_half])
					socket.flush
				end
				Timeout.timeout(10) do
					get('/').should =~ /Welcome to MyCook/
				end
			ensure
				sockets.each do |socket|
					socket.close rescue nil
				end
			end
		end
	end
	
	describe ": MyCook(tm) beta running in a sub-URI" do
		before :all do
			@stub = setup_rails_stub('mycook')
			FileUtils.rm_rf('tmp.webdir')
			FileUtils.mkdir_p('tmp.webdir')
			FileUtils.cp_r('stub/zsfa/.', 'tmp.webdir')
			FileUtils.ln_sf(File.expand_path(@stub.app_root) + "/public", 'tmp.webdir/mycook')
			
			@apache2.add_vhost('passenger.test', File.expand_path('tmp.webdir')) do |vhost|
				vhost << "RailsBaseURI /mycook"
			end
			@apache2.start
		end
		
		after :all do
			FileUtils.rm_rf('tmp.webdir')
			@stub.destroy
		end
		
		before :each do
			@server = "http://passenger.test:#{@apache2.port}/mycook"
		end
		
		it_should_behave_like "MyCook(tm) beta"
		
		it "does not interfere with the root website" do
			@server = "http://passenger.test:#{@apache2.port}"
			get('/').should =~ /Zed, you rock\!/
		end
	end
	
	describe "configuration options" do
		before :all do
			@apache2 << "PassengerMaxPoolSize 3"
			
			@stub = setup_rails_stub('mycook')
			rails_dir = File.expand_path(@stub.app_root) + "/public"
			
			@apache2.add_vhost('mycook.passenger.test', rails_dir)
			
			@apache2.add_vhost('norails.passenger.test', rails_dir) do |vhost|
				vhost << "RailsAutoDetect off"
			end
			
			@stub2 = setup_rails_stub('foobar', 'tmp.stub2')
			rails_dir = File.expand_path(@stub2.app_root) + "/public"
			@apache2.add_vhost('passenger.test', rails_dir) do |vhost|
				vhost << "RailsEnv development"
				vhost << "RailsSpawnMethod conservative"
				vhost << "PassengerUseGlobalQueue on"
			end
			@apache2.start
		end
		
		after :all do
			@stub.destroy
			@stub2.destroy
		end
		
		it "ignores the Rails application if RailsAutoDetect is off" do
			@server = "http://norails.passenger.test:#{@apache2.port}"
			get('/').should_not =~ /MyCook/
		end
		
		specify "setting RailsAutoDetect for one virtual host should not interfere with others" do
			@server = "http://mycook.passenger.test:#{@apache2.port}"
			get('/').should =~ /MyCook/
		end
		
		specify "RailsEnv is per-virtual host" do
			@server = "http://mycook.passenger.test:#{@apache2.port}"
			get('/welcome/rails_env').should == "production"
			
			@server = "http://passenger.test:#{@apache2.port}"
			get('/foo/rails_env').should == "development"
		end
		
		it "supports conservative spawning" do
			@server = "http://passenger.test:#{@apache2.port}"
			get('/foo/backtrace').should_not =~ /framework_spawner/
		end
		
		specify "RailsSpawnMethod spawning is per-virtual host" do
			@server = "http://mycook.passenger.test:#{@apache2.port}"
			get('/welcome/backtrace').should =~ /application_spawner/
		end
		
		describe "PassengerUseGlobalQueue" do
			after :each do
				# Restart Apache to reset the application pool's state.
				@apache2.start
			end
			
			it "is off by default" do
				@server = "http://mycook.passenger.test:#{@apache2.port}"
				
				# Spawn the application.
				get('/')
				
				threads = []
				# Reserve all application pool slots.
				3.times do |i|
					thread = Thread.new do
						File.unlink("#{@stub.app_root}/#{i}.txt") rescue nil
						get("/welcome/sleep_until_exists?name=#{i}.txt")
					end
					threads << thread
				end
				
				# Wait until all application instances are waiting
				# for the quit file.
				while !File.exist?("#{@stub.app_root}/waiting_0.txt") ||
				      !File.exist?("#{@stub.app_root}/waiting_1.txt") ||
				      !File.exist?("#{@stub.app_root}/waiting_2.txt")
					sleep 0.1
				end
				
				# While all slots are reserved, make two more requests.
				first_request_done = false
				second_request_done = false
				thread = Thread.new do
					get("/")
					first_request_done = true
				end
				threads << thread
				thread = Thread.new do
					get("/")
					second_request_done = true
				end
				threads << thread
				
				# These requests should both block.
				sleep 0.5
				first_request_done.should be_false
				second_request_done.should be_false
				
				# One of the requests should still be blocked
				# if one application instance frees up.
				File.open("#{@stub.app_root}/2.txt", 'w')
				begin
					Timeout.timeout(5) do
						while !first_request_done && !second_request_done
							sleep 0.1
						end
					end
				rescue Timeout::Error
				end
				(first_request_done || second_request_done).should be_true
				
				File.open("#{@stub.app_root}/0.txt", 'w')
				File.open("#{@stub.app_root}/1.txt", 'w')
				File.open("#{@stub.app_root}/2.txt", 'w')
				threads.each do |thread|
					thread.join
				end
			end
			
			it "works and is per-virtual host" do
				@server = "http://passenger.test:#{@apache2.port}"
				
				# Spawn the application.
				get('/')
				
				threads = []
				# Reserve all application pool slots.
				3.times do |i|
					thread = Thread.new do
						File.unlink("#{@stub2.app_root}/#{i}.txt") rescue nil
						get("/foo/sleep_until_exists?name=#{i}.txt")
					end
					threads << thread
				end
				
				# Wait until all application instances are waiting
				# for the quit file.
				while !File.exist?("#{@stub2.app_root}/waiting_0.txt") ||
				      !File.exist?("#{@stub2.app_root}/waiting_1.txt") ||
				      !File.exist?("#{@stub2.app_root}/waiting_2.txt")
					sleep 0.1
				end
				
				# While all slots are reserved, make two more requests.
				first_request_done = false
				second_request_done = false
				thread = Thread.new do
					get("/")
					first_request_done = true
				end
				threads << thread
				thread = Thread.new do
					get("/")
					second_request_done = true
				end
				threads << thread
				
				# These requests should both block.
				sleep 0.5
				first_request_done.should be_false
				second_request_done.should be_false
				
				# Both requests should be processed if one application instance frees up.
				File.open("#{@stub2.app_root}/2.txt", 'w')
				begin
					Timeout.timeout(5) do
						while !first_request_done || !second_request_done
							sleep 0.1
						end
					end
				rescue Timeout::Error
				end
				first_request_done.should be_true
				second_request_done.should be_true
				
				File.open("#{@stub2.app_root}/0.txt", 'w')
				File.open("#{@stub2.app_root}/1.txt", 'w')
				File.open("#{@stub2.app_root}/2.txt", 'w')
				threads.each do |thread|
					thread.join
				end
			end
		end
	end
	
	describe "custom app root" do
		before :all do
			@stub = setup_rails_stub('mycook')
			rails_dir = File.expand_path(@stub.app_root) + "/public/welcome"
			@apache2.add_vhost('mycook.passenger.test', rails_dir) do |vhost|
				vhost << "RailsAppRoot \"#{File.expand_path(@stub.app_root)}\""
			end
			@apache2.start
			
			@server = "http://mycook.passenger.test:#{@apache2.port}"
		end
		
		after :all do
			@stub.destroy
		end
		
		it "serves Rails requests as usual" do
			get('/').should =~ /MyCook/
		end
		
		it "uses the specified document root" do
			get('/cached.html').should =~ /cached/
		end
	end
	
	describe "error handling" do
		before :all do
			FileUtils.rm_rf('tmp.webdir')
			FileUtils.mkdir_p('tmp.webdir')
			@webdir = File.expand_path('tmp.webdir')
			@apache2.add_vhost('passenger.test', @webdir) do |vhost|
				vhost << "RailsBaseURI /app-with-nonexistant-rails-version/public"
				vhost << "RailsBaseURI /app-that-crashes-during-startup/public"
				vhost << "RailsBaseURI /app-with-crashing-vendor-rails/public"
			end
			@apache2.start
		end
		
		after :all do
			FileUtils.rm_rf('tmp.webdir')
		end
		
		before :each do
			@server = "http://zsfa.passenger.test:64506"
			@error_page_signature = /<meta name="generator" content="Phusion Passenger">/
		end
		
		it "displays an error page if the Rails application requires a nonexistant Rails version" do
			use_rails_stub('foobar', "#{@webdir}/app-with-nonexistant-rails-version") do |stub|
				File.write(stub.environment_rb) do |content|
					content.sub(/^RAILS_GEM_VERSION = .*$/, "RAILS_GEM_VERSION = '1.9.1234'")
				end
				get("/app-with-nonexistant-rails-version/public").should =~ @error_page_signature
			end
		end
		
		it "displays an error page if the Rails application crashes during startup" do
			use_rails_stub('foobar', "#{@webdir}/app-that-crashes-during-startup") do |stub|
				File.prepend(stub.environment_rb, "raise 'app crash'")
				result = get("/app-that-crashes-during-startup/public")
				result.should =~ @error_page_signature
				result.should =~ /app crash/
			end
		end
		
		it "displays an error page if the Rails application's vendor'ed Rails crashes" do
			use_rails_stub('foobar', "#{@webdir}/app-with-crashing-vendor-rails") do |stub|
				stub.use_vendor_rails('minimal')
				File.append("#{stub.app_root}/vendor/rails/railties/lib/initializer.rb",
					"raise 'vendor crash'")
				result = get("/app-with-crashing-vendor-rails/public")
				result.should =~ @error_page_signature
				result.should =~ /vendor crash/
			end
		end
	end
	
	describe "Rack application running in root URI" do
		before :all do
			@stub = setup_stub('rack')
			@apache2.add_vhost('passenger.test', File.expand_path(@stub.app_root) + "/public")
			@apache2.start
			@server = "http://passenger.test:#{@apache2.port}"
		end
		
		after :all do
			@stub.destroy
		end
		
		it_should_behave_like "HelloWorld Rack application"
	end
	
	describe "Rack application running in sub-URI" do
		before :all do
			FileUtils.rm_rf('tmp.webdir')
			FileUtils.mkdir_p('tmp.webdir')
			@stub = setup_stub('rack')
			@apache2.add_vhost('passenger.test', File.expand_path('tmp.webdir')) do |vhost|
				FileUtils.ln_s(File.expand_path(@stub.app_root) + "/public", 'tmp.webdir/rack')
				vhost << "RackBaseURI /rack"
			end
			@apache2.start
			@server = "http://passenger.test:#{@apache2.port}/rack"
		end
		
		after :all do
			@stub.destroy
			FileUtils.rm_rf('tmp.webdir')
		end
		
		it_should_behave_like "HelloWorld Rack application"
	end
	
	describe "WSGI application running in root URI" do
		before :all do
			@stub = setup_stub('wsgi')
			@apache2.add_vhost('passenger.test', File.expand_path(@stub.app_root) + "/public")
			@apache2.start
			@server = "http://passenger.test:#{@apache2.port}"
		end
		
		after :all do
			@stub.destroy
		end
		
		it_should_behave_like "HelloWorld WSGI application"
	end
	
	##### Helper methods #####
	
	def get(uri)
		if !@apache2.running?
			@apache2.start
		end
		return Net::HTTP.get(URI.parse("#{@server}#{uri}"))
	end
	
	def get_response(uri)
		if !@apache2.running?
			@apache2.start
		end
		return Net::HTTP.get_response(URI.parse("#{@server}#{uri}"))
	end
	
	def post(uri, params = {})
		if !@apache2.running?
			@apache2.start
		end
		url = URI.parse("#{@server}#{uri}")
		if params.values.any? { |x| x.respond_to?(:read) }
			mp = Multipart::MultipartPost.new
			query, headers = mp.prepare_query(params)
			Net::HTTP.start(url.host, url.port) do |http|
				return http.post(url.path, query, headers).body
			end
		else
			return Net::HTTP.post_form(url, params).body
		end
	end
	
	def public_file(name)
		return File.read("#{@stub.app_root}/public/#{name}")
	end
	
	def check_hosts_configuration
		begin
			ok = Resolv.getaddress("passenger.test") == "127.0.0.1"
		rescue Resolv::ResolvError
			ok = false
		end
		if !ok
			message = "To run the integration test, you must update " <<
				"your hosts file.\n" <<
				"Please add these to your /etc/hosts:\n\n" <<
				"  127.0.0.1 passenger.test\n" <<
				"  127.0.0.1 mycook.passenger.test\n" <<
				"  127.0.0.1 zsfa.passenger.test\n" <<
				"  127.0.0.1 norails.passenger.test\n"
			if RUBY_PLATFORM =~ /darwin/
				message << "\n\nThen run:\n\n" <<
					"  lookupd -flushcache      (OS X Tiger)\n\n" <<
					"-OR-\n\n" <<
					"  dscacheutil -flushcache  (OS X Leopard)"
			end
			STDERR.puts "---------------------------"
			STDERR.puts message
			exit!
		end
	end
end
