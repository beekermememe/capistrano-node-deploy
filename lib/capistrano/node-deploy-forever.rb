require "digest/md5"
require "railsless-deploy"
require "multi_json"

def remote_file_exists?(full_path)
  results = []
  invoke_command("if [ -e '#{full_path}' ]; then echo -n 'true'; fi") do |ch, stream, out|
    results << (out == 'true')
  end
  results == [true]
end

def remote_file_content_same_as?(full_path, content)
  results = []
  invoke_command("md5sum #{full_path} | awk '{ print $1 }'") do |ch, stream, out|
    results << (out == Digest::MD5.hexdigest(content))
  end
  results == [true]
end

def remote_file_differs?(full_path, content)
  exists = remote_file_exists?(full_path)
  !exists || exists && !remote_file_content_same_as?(full_path, content)
end

Capistrano::Configuration.instance(:must_exist).load do |configuration|
  default_run_options[:pty] = true
  before "deploy", "deploy:create_release_dir"
  after "deploy:update", "node:install_packages", "node:restart"
  after "deploy:rollback", "node:restart"

  package_json = MultiJson.load(File.open("package.json").read) rescue {}

  set :application, package_json["name"] unless defined? application
  set :app_command, package_json["main"] || "index.js" unless defined? app_command
  set :app_environment, "" unless defined? app_environment

  set :node_binary, "/usr/bin/node" unless defined? node_binary
  set :node_env, "production" unless defined? node_env
  set :node_user, "deploy" unless defined? node_user

  set :stdout_log_path, lambda { "#{shared_path}/log/#{node_env}.out.log" }
  set :stderr_log_path, lambda { "#{shared_path}/log/#{node_env}.err.log" }

  set :forever_start_script, lambda { "#{application}-#{node_env}" } unless defined? upstart_job_name
  _cset(:upstart_file_contents) {
<<EOD
#!upstart
description "#{application} node app"
author      "capistrano"

start on runlevel [2345]
stop on shutdown

respawn
respawn limit 99 5

script
    cd #{current_path} && exec sudo -u #{node_user} NODE_ENV=#{node_env} #{app_environment} #{node_binary} #{current_path}/#{app_command} 2>> #{stderr_log_path} 1>> #{stdout_log_path}
end script
EOD
  }


  namespace :node do
    desc "Check required packages and install if packages are not installed"
    task :install_packages do
      run "mkdir -p #{shared_path}/node_modules"
      run "cp #{release_path}/package.json #{shared_path}"
      run "cp #{release_path}/npm-shrinkwrap.json #{shared_path}" if remote_file_exists?("#{release_path}/npm-shrinkwrap.json")
      run "cd #{shared_path} && npm install #{(node_env != 'production') ? '--dev' : ''} --loglevel warn"
      run "ln -s #{shared_path}/node_modules #{release_path}/node_modules"
    end

    desc "Start the node application"
    task :start do
      "cd /srv/node/stats_d_proxy_server/current/"
      "forever start #{forever_start_script}"
    end

    desc "Stop the node application"
    task :stop do
      "cd /srv/node/stats_d_proxy_server/current/"
      "forever stop #{forever_start_script}"
    end

    desc "Restart the node application"
    task :restart do
      "cd /srv/node/stats_d_proxy_server/current/"
      "forever restart #{forever_start_script}"
    end
  end

  namespace :deploy do
    task :create_release_dir, :except => {:no_release => true} do
      mkdir_releases = "mkdir -p #{fetch :releases_path}"
      mkdir_commands = ["log", "pids"].map {|dir| "mkdir -p #{shared_path}/#{dir}"}
      run mkdir_commands.unshift(mkdir_releases).join(" && ")
    end
  end
end
