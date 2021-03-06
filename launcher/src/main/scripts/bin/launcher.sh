#!/bin/bash
#
# Copyright 2010 Proofpoint, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#
# Platform launcher script
#
# General design goals:
# - need to work on CentOS, Ubuntu, and Mac OSX
# - actions performed should be quick and to the point
# - no monitoring actions whatsoever (i.e. loops) are performed
#
# Commands:
# start (run as daemon)
# stop (stop gracefully)
# restart (run as daemon)
# kill (hard stop)
# status (check status of daemon)
#
# Custom commands (for dev & debugging convenience):
# run (run in foreground)
#
# Expects config under "etc":
#   jvm.config
#   config.properties
#
# Options:
# --config to override config file
# --jvm-config to override jvm config file
# --pid-file to override PID file
# --log-file to override log file
# --log-levels-file to override logging configuration
#
# Logs to var/log/launcher.log when run as daemon
# Logs to console when run in foreground, unless log file provided
#
# Libs must be installed under "lib"
#
# Requires Java to be in PATH


# ========================================
# Utilities
# ========================================
function getParentDirPath() {
    pushd "$PWD" > /dev/null
    dir=`dirname $0`
    if [ $dir == "." ]; then
        cd ..
        path=$PWD
    else
        path=`dirname $dir`
    fi
    popd > /dev/null
    PARENT_DIR=$path
}


# ========================================
# Common globals
# ========================================
getParentDirPath $0
HOME_DIR=$PARENT_DIR
VAR_DIR=$HOME_DIR/var
RUN_DIR=$VAR_DIR/run
LOG_DIR=$VAR_DIR/log
CFG_DIR=$HOME_DIR/etc
TIMEOUT_SECS=10


# ========================================
# Define error codes
# ========================================
ERR_GENERIC=1
ERR_INVALID_ARGS=2
ERR_UNSUPPORTED=3
ERR_CONFIG_MISSING=6
ERR_NOT_RUNNING=7


# ========================================
# program option var defaults
# ========================================
show_verbose=1
jvm_config=$CFG_DIR/jvm.config
config_props=$CFG_DIR/config.properties
pid_file=$RUN_DIR/launcher.pid
log_file=$LOG_DIR/launcher.log
log_levels_file=$CFG_DIR/log.properties


# ========================================
# Log Functions
# ========================================
# Write to stderr
stderr() {
    echo "$1" >&2
}

log_info() {
    msg="$1"
    stderr "$msg"
}

# Display error message and exit
die() {
    msg=$1
    if [ -n "$1" ]; then
        msg="Error: $1"
    else
        msg="Terminated"
    fi

    stderr "$msg"

    exit $ERR_NOT_RUNNING
}


# ========================================
# Common Functions
# ========================================

# Determine PID of the Agent running
getPid() {
    PID=
    if [ -r "$pid_file" ]; then
        PID=`cat $pid_file`
    fi
}

# Create PID file
setPid() {
    PID=
    if [ $1 ]; then
        PID=$1
        echo $PID > $pid_file
    fi
}

# Remove PID file
clearPid() {
    PID=
    if [ -r "$pid_file" ]; then
        PID=`cat $pid_file`
        rm -f "$pid_file"
    fi
}

# Check if a given PID is alive
# returns 0 if alive, else returns 1
isPidAlive() {
    local isAlive=1
    if [ $1 ]; then
        ps -p $1 > /dev/null
        isAlive=$?
    else
        if [ $show_verbose -eq 0 ]; then
            log_info "isPidAlive: Missing PID argument!"
        fi
    fi
    echo $isAlive
}

# Get Java command line
function build_java_cmd() {
    [ -r "$jvm_config" ] || die "JVM config file is missing: $jvm_config"
    [ -r "$config_props" ] || die "Config file is missing: $config_props"

    JAVA_CMD=

    JVM_PROPS=`sed -n -e '/^[^#]/p' $jvm_config | paste -s -`

    log_option=
    if [ -z "$1" ] ; then
        # only set if not specified by callee; used for "start" not "run"
        log_option="-Dlog.output-file=$log_file"
    fi

    log_levels_option=
    if [ -r "$log_levels_file" ] ; then
        log_levels_option="-Dlog.levels-file=$log_levels_file"
    fi

    jar_path="$HOME_DIR/lib/main.jar"

    JAVA_CMD="java $JVM_PROPS -Dconfig=$config_props $log_levels_option $log_option -jar $jar_path"
}


# Start up a service
function start() {
    getPid
    isAlive=`isPidAlive $PID`
    if [ $isAlive -eq 0 ]; then
        log_info "Already running as $PID"
    else

        build_java_cmd
        cd $HOME_DIR
        nohup $JAVA_CMD &> /dev/null &
        setPid $!

        if [ -n "$PID" ]; then
            log_info "Started as $PID"
        else
            die "Failed to start.  See logs in $LOG_DIR."
        fi
    fi
}


# Run a service
function run() {
    getPid
    isAlive=`isPidAlive $PID`
    if [ $isAlive -eq 0 ]; then
        log_info "Already running as $PID"
    else
        cd $HOME_DIR
        build_java_cmd "no_log_file"
        $JAVA_CMD
    fi
}


# Shut down a service
function stop() {
    getPid
    isAlive=`isPidAlive $PID`
    if [ $isAlive -eq 0 ]; then
        OLD_PID=$PID
        kill $PID

        start_time=`date +%s`
        while [ `isPidAlive $PID` -eq 0 ]
        do
            sleep 0.1
            current_time=`date +%s`
            if [ `expr $current_time - $start_time` -ge $TIMEOUT_SECS ]
            then
                kill -9 $PID
            fi
        done

        clearPid

        log_info "Stopped $OLD_PID"
    else
        log_info "Not running"
    fi
}


# Force shut down a service
function stop_force() {
    getPid
    isAlive=`isPidAlive $PID`
    if [ $isAlive -eq 0 ]; then
        OLD_PID=$PID
        kill -9 $PID

        while [ `isPidAlive $PID` -eq 0 ]
        do
            sleep 0.1
        done

        clearPid

        log_info "Killed $OLD_PID"
    else
        log_info "Not running"
    fi
}


# Get status of service process
function status() {
    getPid
    isAlive=`isPidAlive $PID`
    if [ $isAlive -eq 0 ]; then
        log_info "Running as $PID"
    else
        log_info "Not running"
        exit $ERR_NOT_RUNNING
    fi
}


# Show help info
function show_help() {
    echo "Usage: $(basename $0) [options] <command>"
    echo
    echo "Commands:"
    echo "  run"
    echo "  start"
    echo "  stop"
    echo "  kill"
    echo "  status"
    echo
    echo "Options:"
    echo "    -v, --verbose               Run verbosely"
    echo "        --jvm-config FILE       Defaults to INSTALL_PATH/etc/jvm.config"
    echo "        --config FILE           Defaults to INSTALL_PATH/etc/config.properties"
    echo "        --pid-file FILE         Defaults to INSTALL_PATH/var/run/launcher.pid"
    echo "        --log-file FILE         Defaults to INSTALL_PATH/var/log/launcher.log (daemon only)"
    echo "        --log-levels-file FILE  Defaults to INSTALL_PATH/etc/log.config"
    echo "    -h, --help                  Display this screen"
}


#===========================================
# Main
#===========================================

# get program name
program_name=$(basename $0)

# Check for options
while [ $# -gt 0 ]
do
    case "$1" in
       --verbose | -v) 		show_verbose=0;;
       --help | -h) 		show_help;exit 0;;
       --jvm-config)		jvm_config="$2";shift;;
       --config)		config="$2";shift;;
       --pid-file)		pid_file="$2";shift;;
       --log-file)        	log_file="$2";shift;;
       --log-levels-file)	log_levels_file="$2";shift;;
       --)        		shift;break;;
       -*)        		show_help;exit 0;;
       *)         		break;;
    esac
    shift
done

# make sure required dirs exist
mkdir -p $RUN_DIR
mkdir -p $LOG_DIR

# check for argument
if [ -z "$*" ]; then
	command="unknown"
elif [ -n "$*" ]; then
	command=$*
fi

# run the command
case $command in
	"run")
		run
		;;
	"start")
		start
		;;
	"stop")
		stop
		;;
	"kill")
		stop_force
		;;
	"restart")
		stop
		start
		;;
	"status")
                status
		;;
	"unknown")
		log_info "Expected a single command"
		exit $ERR_INVALID_ARGS
		;;
	*)
		log_info "Unsupported command: $command"
		exit $ERR_UNSUPPORTED
		;;
esac

