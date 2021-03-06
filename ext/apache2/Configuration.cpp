/*
 *  Phusion Passenger - http://www.modrails.com/
 *  Copyright (C) 2008  Phusion
 *
 *  Phusion Passenger is a trademark of Hongli Lai & Ninh Bui.
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; version 2 of the License.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along
 *  with this program; if not, write to the Free Software Foundation, Inc.,
 *  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */
#include <apr_strings.h>
#include <algorithm>
#include <cstdlib>
#include "Configuration.h"
#include "Utils.h"

using namespace Passenger;

extern "C" module AP_MODULE_DECLARE_DATA passenger_module;

#define DEFAULT_LOG_LEVEL 0
#define DEFAULT_MAX_POOL_SIZE 6
#define DEFAULT_POOL_IDLE_TIME 300
#define DEFAULT_MAX_INSTANCES_PER_APP 0


template<typename T> static apr_status_t
destroy_config_struct(void *x) {
	delete (T *) x;
	return APR_SUCCESS;
}

static DirConfig *
create_dir_config_struct(apr_pool_t *pool) {
	DirConfig *config = new DirConfig();
	apr_pool_cleanup_register(pool, config, destroy_config_struct<DirConfig>, apr_pool_cleanup_null);
	return config;
}

static ServerConfig *
create_server_config_struct(apr_pool_t *pool) {
	ServerConfig *config = new ServerConfig();
	apr_pool_cleanup_register(pool, config, destroy_config_struct<ServerConfig>, apr_pool_cleanup_null);
	return config;
}

extern "C" {

void *
passenger_config_create_dir(apr_pool_t *p, char *dirspec) {
	DirConfig *config = create_dir_config_struct(p);
	config->enabled = DirConfig::UNSET;
	config->autoDetectRails = DirConfig::UNSET;
	config->autoDetectRack = DirConfig::UNSET;
	config->autoDetectWSGI = DirConfig::UNSET;
	config->allowModRewrite = DirConfig::UNSET;
	config->railsEnv = NULL;
	config->rackEnv = NULL;
	config->railsAppRoot = NULL;
	config->spawnMethod = DirConfig::SM_UNSET;
	config->frameworkSpawnerTimeout = -1;
	config->appSpawnerTimeout = -1;
	config->maxRequests = 0;
	config->maxRequestsSpecified = false;
	config->memoryLimit = 0;
	config->memoryLimitSpecified = false;
	config->highPerformance = DirConfig::UNSET;
	config->useGlobalQueue = DirConfig::UNSET;
	return config;
}

void *
passenger_config_merge_dir(apr_pool_t *p, void *basev, void *addv) {
	DirConfig *config = create_dir_config_struct(p);
	DirConfig *base = (DirConfig *) basev;
	DirConfig *add = (DirConfig *) addv;
	
	config->enabled = (add->enabled == DirConfig::UNSET) ? base->enabled : add->enabled;
	
	config->railsBaseURIs = base->railsBaseURIs;
	for (set<string>::const_iterator it(add->railsBaseURIs.begin()); it != add->railsBaseURIs.end(); it++) {
		config->railsBaseURIs.insert(*it);
	}
	config->rackBaseURIs = base->rackBaseURIs;
	for (set<string>::const_iterator it(add->rackBaseURIs.begin()); it != add->rackBaseURIs.end(); it++) {
		config->rackBaseURIs.insert(*it);
	}
	
	config->autoDetectRails = (add->autoDetectRails == DirConfig::UNSET) ? base->autoDetectRails : add->autoDetectRails;
	config->autoDetectRack = (add->autoDetectRack == DirConfig::UNSET) ? base->autoDetectRack : add->autoDetectRack;
	config->autoDetectWSGI = (add->autoDetectWSGI == DirConfig::UNSET) ? base->autoDetectWSGI : add->autoDetectWSGI;
	config->allowModRewrite = (add->allowModRewrite == DirConfig::UNSET) ? base->allowModRewrite : add->allowModRewrite;
	config->railsEnv = (add->railsEnv == NULL) ? base->railsEnv : add->railsEnv;
	config->rackEnv = (add->rackEnv == NULL) ? base->rackEnv : add->rackEnv;
	config->railsAppRoot = (add->railsAppRoot == NULL) ? base->railsAppRoot : add->railsAppRoot;
	config->spawnMethod = (add->spawnMethod == DirConfig::SM_UNSET) ? base->spawnMethod : add->spawnMethod;
	config->frameworkSpawnerTimeout = (add->frameworkSpawnerTimeout == -1) ? base->frameworkSpawnerTimeout : add->frameworkSpawnerTimeout;
	config->appSpawnerTimeout = (add->appSpawnerTimeout == -1) ? base->appSpawnerTimeout : add->appSpawnerTimeout;
	config->maxRequests = (add->maxRequestsSpecified) ? add->maxRequests : base->maxRequests;
	config->maxRequestsSpecified = base->maxRequestsSpecified || add->maxRequestsSpecified;
	config->memoryLimit = (add->memoryLimitSpecified) ? add->memoryLimit : base->memoryLimit;
	config->memoryLimitSpecified = base->memoryLimitSpecified || add->memoryLimitSpecified;
	config->highPerformance = (add->highPerformance == DirConfig::UNSET) ? base->highPerformance : add->highPerformance;
	config->useGlobalQueue = (add->useGlobalQueue == DirConfig::UNSET) ? base->useGlobalQueue : add->useGlobalQueue;
	return config;
}

void *
passenger_config_create_server(apr_pool_t *p, server_rec *s) {
	ServerConfig *config = create_server_config_struct(p);
	config->ruby = NULL;
	config->root = NULL;
	config->logLevel = DEFAULT_LOG_LEVEL;
	config->maxPoolSize = DEFAULT_MAX_POOL_SIZE;
	config->maxPoolSizeSpecified = false;
	config->maxInstancesPerApp = DEFAULT_MAX_INSTANCES_PER_APP;
	config->maxInstancesPerAppSpecified = false;
	config->poolIdleTime = DEFAULT_POOL_IDLE_TIME;
	config->poolIdleTimeSpecified = false;
	config->userSwitching = true;
	config->userSwitchingSpecified = false;
	config->defaultUser = NULL;
	return config;
}

void *
passenger_config_merge_server(apr_pool_t *p, void *basev, void *addv) {
	ServerConfig *config = create_server_config_struct(p);
	ServerConfig *base = (ServerConfig *) basev;
	ServerConfig *add = (ServerConfig *) addv;
	
	config->ruby = (add->ruby == NULL) ? base->ruby : add->ruby;
	config->root = (add->root == NULL) ? base->root : add->root;
	config->logLevel = (add->logLevel) ? base->logLevel : add->logLevel;
	config->maxPoolSize = (add->maxPoolSizeSpecified) ? base->maxPoolSize : add->maxPoolSize;
	config->maxPoolSizeSpecified = base->maxPoolSizeSpecified || add->maxPoolSizeSpecified;
	config->maxInstancesPerApp = (add->maxInstancesPerAppSpecified) ? base->maxInstancesPerApp : add->maxInstancesPerApp;
	config->maxInstancesPerAppSpecified = base->maxInstancesPerAppSpecified || add->maxInstancesPerAppSpecified;
	config->poolIdleTime = (add->poolIdleTime) ? base->poolIdleTime : add->poolIdleTime;
	config->poolIdleTimeSpecified = base->poolIdleTimeSpecified || add->poolIdleTimeSpecified;
	config->userSwitching = (add->userSwitchingSpecified) ? add->userSwitching : base->userSwitching;
	config->userSwitchingSpecified = base->userSwitchingSpecified || add->userSwitchingSpecified;
	config->defaultUser = (add->defaultUser == NULL) ? base->defaultUser : add->defaultUser;
	return config;
}

void
passenger_config_merge_all_servers(apr_pool_t *pool, server_rec *main_server) {
	ServerConfig *final = (ServerConfig *) passenger_config_create_server(pool, main_server);
	server_rec *s;
	
	for (s = main_server; s != NULL; s = s->next) {
		ServerConfig *config = (ServerConfig *) ap_get_module_config(s->module_config, &passenger_module);
		final->ruby = (final->ruby != NULL) ? final->ruby : config->ruby;
		final->root = (final->root != NULL) ? final->root : config->root;
		final->logLevel = (final->logLevel != 0) ? final->logLevel : config->logLevel;
		final->maxPoolSize = (final->maxPoolSizeSpecified) ? final->maxPoolSize : config->maxPoolSize;
		final->maxPoolSizeSpecified = final->maxPoolSizeSpecified || config->maxPoolSizeSpecified;
		final->maxInstancesPerApp = (final->maxInstancesPerAppSpecified) ? final->maxInstancesPerApp : config->maxInstancesPerApp;
		final->maxInstancesPerAppSpecified = final->maxInstancesPerAppSpecified || config->maxInstancesPerAppSpecified;
		final->poolIdleTime = (final->poolIdleTimeSpecified) ? final->poolIdleTime : config->poolIdleTime;
		final->poolIdleTimeSpecified = final->poolIdleTimeSpecified || config->poolIdleTimeSpecified;
		final->userSwitching = (config->userSwitchingSpecified) ? config->userSwitching : final->userSwitching;
		final->userSwitchingSpecified = final->userSwitchingSpecified || config->userSwitchingSpecified;
		final->defaultUser = (final->defaultUser != NULL) ? final->defaultUser : config->defaultUser;
	}
	for (s = main_server; s != NULL; s = s->next) {
		ServerConfig *config = (ServerConfig *) ap_get_module_config(s->module_config, &passenger_module);
		*config = *final;
	}
}


/*************************************************
 * Passenger settings
 *************************************************/

static const char *
cmd_passenger_root(cmd_parms *cmd, void *pcfg, const char *arg) {
	ServerConfig *config = (ServerConfig *) ap_get_module_config(
		cmd->server->module_config, &passenger_module);
	config->root = arg;
	return NULL;
}

static const char *
cmd_passenger_log_level(cmd_parms *cmd, void *pcfg, const char *arg) {
	ServerConfig *config = (ServerConfig *) ap_get_module_config(
		cmd->server->module_config, &passenger_module);
	char *end;
	long int result;
	
	result = strtol(arg, &end, 10);
	if (*end != '\0') {
		return "Invalid number specified for PassengerLogLevel.";
	} else if (result < 0 || result > 9) {
		return "Value for PassengerLogLevel must be between 0 and 9.";
	} else {
		config->logLevel = (unsigned int) result;
		return NULL;
	}
}

static const char *
cmd_passenger_ruby(cmd_parms *cmd, void *pcfg, const char *arg) {
	ServerConfig *config = (ServerConfig *) ap_get_module_config(
		cmd->server->module_config, &passenger_module);
	config->ruby = arg;
	return NULL;
}

static const char *
cmd_passenger_max_pool_size(cmd_parms *cmd, void *pcfg, const char *arg) {
	ServerConfig *config = (ServerConfig *) ap_get_module_config(
		cmd->server->module_config, &passenger_module);
	char *end;
	long int result;
	
	result = strtol(arg, &end, 10);
	if (*end != '\0') {
		return "Invalid number specified for PassengerMaxPoolSize.";
	} else if (result <= 0) {
		return "Value for PassengerMaxPoolSize must be greater than 0.";
	} else {
		config->maxPoolSize = (unsigned int) result;
		config->maxPoolSizeSpecified = true;
		return NULL;
	}
}

static const char *
cmd_passenger_max_instances_per_app(cmd_parms *cmd, void *pcfg, const char *arg) {
	ServerConfig *config = (ServerConfig *) ap_get_module_config(
		cmd->server->module_config, &passenger_module);
	char *end;
	long int result;
	
	result = strtol(arg, &end, 10);
	if (*end != '\0') {
		return "Invalid number specified for PassengerMaxInstancesPerApp.";
	} else {
		config->maxInstancesPerApp = (unsigned int) result;
		config->maxInstancesPerAppSpecified = true;
		return NULL;
	}
}

static const char *
cmd_passenger_pool_idle_time(cmd_parms *cmd, void *pcfg, const char *arg) {
	ServerConfig *config = (ServerConfig *) ap_get_module_config(
		cmd->server->module_config, &passenger_module);
	char *end;
	long int result;
	
	result = strtol(arg, &end, 10);
	if (*end != '\0') {
		return "Invalid number specified for PassengerPoolIdleTime.";
	} else if (result <= 0) {
		return "Value for PassengerPoolIdleTime must be greater than 0.";
	} else {
		config->poolIdleTime = (unsigned int) result;
		config->poolIdleTimeSpecified = true;
		return NULL;
	}
}

static const char *
cmd_passenger_use_global_queue(cmd_parms *cmd, void *pcfg, int arg) {
	DirConfig *config = (DirConfig *) pcfg;
	if (arg) {
		config->useGlobalQueue = DirConfig::ENABLED;
	} else {
		config->useGlobalQueue = DirConfig::DISABLED;
	}
	return NULL;
}

static const char *
cmd_passenger_user_switching(cmd_parms *cmd, void *pcfg, int arg) {
	ServerConfig *config = (ServerConfig *) ap_get_module_config(
		cmd->server->module_config, &passenger_module);
	config->userSwitching = arg;
	config->userSwitchingSpecified = true;
	return NULL;
}

static const char *
cmd_passenger_default_user(cmd_parms *cmd, void *dummy, const char *arg) {
	ServerConfig *config = (ServerConfig *) ap_get_module_config(
		cmd->server->module_config, &passenger_module);
	config->defaultUser = arg;
	return NULL;
}

static const char *
cmd_passenger_max_requests(cmd_parms *cmd, void *pcfg, const char *arg) {
	DirConfig *config = (DirConfig *) pcfg;
	char *end;
	long int result;
	
	result = strtol(arg, &end, 10);
	if (*end != '\0') {
		return "Invalid number specified for PassengerMaxRequests.";
	} else if (result < 0) {
		return "Value for PassengerMaxRequests must be greater than or equal to 0.";
	} else {
		config->maxRequests = (unsigned long) result;
		config->maxRequestsSpecified = true;
		return NULL;
	}
}

static const char *
cmd_passenger_high_performance(cmd_parms *cmd, void *pcfg, int arg) {
	DirConfig *config = (DirConfig *) pcfg;
	if (arg) {
		config->highPerformance = DirConfig::ENABLED;
	} else {
		config->highPerformance = DirConfig::DISABLED;
	}
	return NULL;
}

static const char *
cmd_passenger_enabled(cmd_parms *cmd, void *pcfg, int arg) {
	DirConfig *config = (DirConfig *) pcfg;
	if (arg) {
		config->enabled = DirConfig::ENABLED;
	} else {
		config->enabled = DirConfig::DISABLED;
	}
	return NULL;
}


/*************************************************
 * Rails-specific settings
 *************************************************/

static const char *
cmd_rails_base_uri(cmd_parms *cmd, void *pcfg, const char *arg) {
	DirConfig *config = (DirConfig *) pcfg;
	config->railsBaseURIs.insert(arg);
	return NULL;
}

static const char *
cmd_rails_auto_detect(cmd_parms *cmd, void *pcfg, int arg) {
	DirConfig *config = (DirConfig *) pcfg;
	config->autoDetectRails = (arg) ? DirConfig::ENABLED : DirConfig::DISABLED;
	return NULL;
}

static const char *
cmd_rails_allow_mod_rewrite(cmd_parms *cmd, void *pcfg, int arg) {
	DirConfig *config = (DirConfig *) pcfg;
	config->allowModRewrite = (arg) ? DirConfig::ENABLED : DirConfig::DISABLED;
	return NULL;
}

static const char *
cmd_rails_env(cmd_parms *cmd, void *pcfg, const char *arg) {
	DirConfig *config = (DirConfig *) pcfg;
	config->railsEnv = arg;
	return NULL;
}

static const char *
cmd_rails_app_root(cmd_parms *cmd, void *pcfg, const char *arg) {
	DirConfig *config = (DirConfig *) pcfg;
	config->railsAppRoot = arg;
	return NULL;
}

static const char *
cmd_rails_spawn_method(cmd_parms *cmd, void *pcfg, const char *arg) {
	DirConfig *config = (DirConfig *) pcfg;
	if (strcmp(arg, "smart") == 0) {
		config->spawnMethod = DirConfig::SM_SMART;
	} else if (strcmp(arg, "smart-lv2") == 0) {
		config->spawnMethod = DirConfig::SM_SMART_LV2;
	} else if (strcmp(arg, "conservative") == 0) {
		config->spawnMethod = DirConfig::SM_CONSERVATIVE;
	} else {
		return "RailsSpawnMethod may only be 'smart', 'smart-lv2' or 'conservative'.";
	}
	return NULL;
}

static const char *
cmd_rails_framework_spawner_idle_time(cmd_parms *cmd, void *pcfg, const char *arg) {
	DirConfig *config = (DirConfig *) pcfg;
	char *end;
	long int result;
	
	result = strtol(arg, &end, 10);
	if (*end != '\0') {
		return "Invalid number specified for RailsFrameworkSpawnerIdleTime.";
	} else if (result < 0) {
		return "Value for RailsFrameworkSpawnerIdleTime must be at least 0.";
	} else {
		config->frameworkSpawnerTimeout = result;
		return NULL;
	}
}

static const char *
cmd_rails_app_spawner_idle_time(cmd_parms *cmd, void *pcfg, const char *arg) {
	DirConfig *config = (DirConfig *) pcfg;
	char *end;
	long int result;
	
	result = strtol(arg, &end, 10);
	if (*end != '\0') {
		return "Invalid number specified for RailsAppSpawnerIdleTime.";
	} else if (result < 0) {
		return "Value for RailsAppSpawnerIdleTime must be at least 0.";
	} else {
		config->appSpawnerTimeout = result;
		return NULL;
	}
}


/*************************************************
 * Rack-specific settings
 *************************************************/

static const char *
cmd_rack_base_uri(cmd_parms *cmd, void *pcfg, const char *arg) {
	DirConfig *config = (DirConfig *) pcfg;
	config->rackBaseURIs.insert(arg);
	return NULL;
}

static const char *
cmd_rack_auto_detect(cmd_parms *cmd, void *pcfg, int arg) {
	DirConfig *config = (DirConfig *) pcfg;
	config->autoDetectRack = (arg) ? DirConfig::ENABLED : DirConfig::DISABLED;
	return NULL;
}

static const char *
cmd_rack_env(cmd_parms *cmd, void *pcfg, const char *arg) {
	DirConfig *config = (DirConfig *) pcfg;
	config->rackEnv = arg;
	return NULL;
}


/*************************************************
 * WSGI-specific settings
 *************************************************/

static const char *
cmd_wsgi_auto_detect(cmd_parms *cmd, void *pcfg, int arg) {
	DirConfig *config = (DirConfig *) pcfg;
	config->autoDetectWSGI = (arg) ? DirConfig::ENABLED : DirConfig::DISABLED;
	return NULL;
}


/*************************************************
 * Obsolete settings
 *************************************************/

static const char *
cmd_rails_spawn_server(cmd_parms *cmd, void *pcfg, const char *arg) {
	fprintf(stderr, "WARNING: The 'RailsSpawnServer' option is obsolete. "
		"Please specify 'PassengerRoot' instead. The correct value was "
		"given to you by 'passenger-install-apache2-module'.");
	fflush(stderr);
	return NULL;
}


// Workaround for some weird C++-specific compiler error.
typedef const char * (*Take0Func)();
typedef const char * (*Take1Func)();

const command_rec passenger_commands[] = {
	// Passenger settings.
	AP_INIT_TAKE1("PassengerRoot",
		(Take1Func) cmd_passenger_root,
		NULL,
		RSRC_CONF,
		"The Passenger root folder."),
	AP_INIT_TAKE1("PassengerLogLevel",
		(Take1Func) cmd_passenger_log_level,
		NULL,
		RSRC_CONF,
		"Passenger log verbosity."),
	AP_INIT_TAKE1("PassengerRuby",
		(Take1Func) cmd_passenger_ruby,
		NULL,
		RSRC_CONF,
		"The Ruby interpreter to use."),
	AP_INIT_TAKE1("PassengerMaxPoolSize",
		(Take1Func) cmd_passenger_max_pool_size,
		NULL,
		RSRC_CONF,
		"The maximum number of simultaneously alive application instances."),
	AP_INIT_TAKE1("PassengerMaxInstancesPerApp",
		(Take1Func) cmd_passenger_max_instances_per_app,
		NULL,
		RSRC_CONF,
		"The maximum number of simultaneously alive application instances a single application may occupy."),
	AP_INIT_TAKE1("PassengerPoolIdleTime",
		(Take1Func) cmd_passenger_pool_idle_time,
		NULL,
		RSRC_CONF,
		"The maximum number of seconds that an application may be idle before it gets terminated."),
	AP_INIT_FLAG("PassengerUseGlobalQueue",
		(Take1Func) cmd_passenger_use_global_queue,
		NULL,
		OR_OPTIONS | ACCESS_CONF | RSRC_CONF,
		"Enable or disable Passenger's global queuing mode mode."),
	AP_INIT_FLAG("PassengerUserSwitching",
		(Take1Func) cmd_passenger_user_switching,
		NULL,
		RSRC_CONF,
		"Whether to enable user switching support."),
	AP_INIT_TAKE1("PassengerDefaultUser",
		(Take1Func) cmd_passenger_default_user,
		NULL,
		RSRC_CONF,
		"The user that Rails/Rack applications must run as when user switching fails or is disabled."),
	AP_INIT_TAKE1("PassengerMaxRequests",
		(Take1Func) cmd_passenger_max_requests,
		NULL,
		OR_LIMIT | ACCESS_CONF | RSRC_CONF,
		"The maximum number of requests that an application instance may process."),
	AP_INIT_FLAG("PassengerHighPerformance", // TODO: document this
		(Take1Func) cmd_passenger_high_performance,
		NULL,
		ACCESS_CONF | RSRC_CONF,
		"Enable or disable Passenger's high performance mode."),
	AP_INIT_FLAG("PassengerEnabled", // TODO: document this
		(Take1Func) cmd_passenger_enabled,
		NULL,
		OR_ALL,
		"Enable or disable Phusion Passenger."),

	// Rails-specific settings.
	AP_INIT_TAKE1("RailsBaseURI",
		(Take1Func) cmd_rails_base_uri,
		NULL,
		OR_OPTIONS | ACCESS_CONF | RSRC_CONF,
		"Reserve the given URI to a Rails application."),
	AP_INIT_FLAG("RailsAutoDetect",
		(Take1Func) cmd_rails_auto_detect,
		NULL,
		RSRC_CONF,
		"Whether auto-detection of Ruby on Rails applications should be enabled."),
	AP_INIT_FLAG("RailsAllowModRewrite",
		(Take1Func) cmd_rails_allow_mod_rewrite,
		NULL,
		RSRC_CONF,
		"Whether custom mod_rewrite rules should be allowed."),
	AP_INIT_TAKE1("RailsEnv",
		(Take1Func) cmd_rails_env,
		NULL,
		OR_OPTIONS | ACCESS_CONF | RSRC_CONF,
		"The environment under which a Rails app must run."),
	AP_INIT_TAKE1("RailsAppRoot",
		(Take1Func) cmd_rails_app_root,
		NULL,
		OR_OPTIONS | ACCESS_CONF | RSRC_CONF,
		"Overrides the Rails application root"),
	AP_INIT_TAKE1("RailsSpawnMethod",
		(Take1Func) cmd_rails_spawn_method,
		NULL,
		RSRC_CONF,
		"The spawn method to use."),
	AP_INIT_TAKE1("RailsFrameworkSpawnerIdleTime", // TODO: document this
		(Take1Func) cmd_rails_framework_spawner_idle_time,
		NULL,
		RSRC_CONF,
		"The maximum number of seconds that a framework spawner may be idle before it is shutdown."),
	AP_INIT_TAKE1("RailsAppSpawnerIdleTime", // TODO: document this
		(Take1Func) cmd_rails_app_spawner_idle_time,
		NULL,
		RSRC_CONF,
		"The maximum number of seconds that an application spawner may be idle before it is shutdown."),
	
	// Rack-specific settings.
	AP_INIT_TAKE1("RackBaseURI",
		(Take1Func) cmd_rack_base_uri,
		NULL,
		OR_OPTIONS | ACCESS_CONF | RSRC_CONF,
		"Reserve the given URI to a Rack application."),
	AP_INIT_FLAG("RackAutoDetect",
		(Take1Func) cmd_rack_auto_detect,
		NULL,
		RSRC_CONF,
		"Whether auto-detection of Rack applications should be enabled."),
	AP_INIT_TAKE1("RackEnv",
		(Take1Func) cmd_rack_env,
		NULL,
		OR_OPTIONS | ACCESS_CONF | RSRC_CONF,
		"The environment under which a Rack app must run."),
	
	// WSGI-specific settings.
	AP_INIT_FLAG("PassengerWSGIAutoDetect",
		(Take1Func) cmd_wsgi_auto_detect,
		NULL,
		RSRC_CONF,
		"Whether auto-detection of WSGI applications should be enabled."),
	
	// Backwards compatibility options.
	AP_INIT_TAKE1("RailsRuby",
		(Take1Func) cmd_passenger_ruby,
		NULL,
		RSRC_CONF,
		"Deprecated option."),
	AP_INIT_TAKE1("RailsMaxPoolSize",
		(Take1Func) cmd_passenger_max_pool_size,
		NULL,
		RSRC_CONF,
		"Deprecated option."),
	AP_INIT_TAKE1("RailsMaxInstancesPerApp",
		(Take1Func) cmd_passenger_max_instances_per_app,
		NULL,
		RSRC_CONF,
		"Deprecated option"),
	AP_INIT_TAKE1("RailsPoolIdleTime",
		(Take1Func) cmd_passenger_pool_idle_time,
		NULL,
		RSRC_CONF,
		"Deprecated option."),
	AP_INIT_FLAG("RailsUserSwitching",
		(Take1Func) cmd_passenger_user_switching,
		NULL,
		RSRC_CONF,
		"Deprecated option."),
	AP_INIT_TAKE1("RailsDefaultUser",
		(Take1Func) cmd_passenger_default_user,
		NULL,
		RSRC_CONF,
		"Deprecated option."),
	
	// Obsolete options.
	AP_INIT_TAKE1("RailsSpawnServer",
		(Take1Func) cmd_rails_spawn_server,
		NULL,
		RSRC_CONF,
		"Obsolete option."),
	
	{ NULL }
};

} // extern "C"
