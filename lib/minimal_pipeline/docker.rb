# frozen_string_literal: true

require 'open3'
require 'docker'
require 'json'
require 'securerandom'

class MinimalPipeline
  # Here is an example of how to use this class to manage Docker containers.
  #
  # ```
  # docker = MinimalPipeline::Docker.new
  # keystore = MinimalPipeline::Keystore.new
  #
  # deploy_env = ENV['DEPLOY_ENV']
  # docker_repo = keystore.retrieve("#{deploy_env}_EXAMPLE_ECR_REPO")
  # docker_image = "#{docker_repo}/example:latest"
  # docker.build_docker_image(docker_image, build_context: 'containers/example')
  # docker.push_docker_image(docker_image)
  # ```
  class Docker
    def initialize; end

    # Finds the absolute path to a given executable
    #
    # @param cmd [String] The name of the executable to locate
    # @return [String] The absolute path to the executable
    def which(cmd)
      exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
      ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
        exts.each do |ext|
          exe = File.join(path, "#{cmd}#{ext}")
          return exe if File.executable?(exe) && !File.directory?(exe)
        end
      end
      nil
    end

    # Outputs JSON build output lines as human readible text
    #
    # @param build_output [String] Raw JSON build output line
    def build_output(build_output)
      # Each line of the response is its own JSON structure
      build_output.each_line do |l|
        if (log = JSON.parse(l)) && log.key?('stream')
          $stdout.puts log['stream']
        end
      end
    rescue JSON::ParserError
      $stdout.puts "Bad JSON parse\n"
      $stdout.puts build_output
    end

    # Cleans up docker images
    #
    # @param image_id [String] The Docker container ID to delete
    def clean_up_image(image_id)
      image = ::Docker::Image.get(image_id)
      image.remove(force: true)
    end

    # Builds a docker image from a Dockerfile
    #
    # @param image_id [String] The name of the docker image
    # @param build_context [String] The build context for Dockerfile
    # @param dockerfile [String] The path to Dockerfile
    # @param build_args [Hash] Additional build args to pass to Docker
    # @param timeout [Integer] The Docker build timeout
    # @param options Additional options to pass to docker API
    #
    # For a full list of options, see https://docs.docker.com/engine/api/v1.37/#operation/ImageBuild
    #
    # rubocop:disable Metrics/ParameterLists
    def build_docker_image(image_id, build_context: '.',
                           dockerfile: 'Dockerfile', build_args: {},
                           timeout: 600, **options)

      build_args_json = generate_build_args_json(build_args)

      args = populate_args_hash(image_id, build_args_json, dockerfile)
      options.each { |key, value| args[key] = value }

      puts "Build args: #{args.inspect}" if ENV['DEBUG']
      build_image(build_context, args, timeout)
    end
    # rubocop:enable Metrics/ParameterLists

    # Pushes a docker image from local to AWS ECR.
    # This handles login, the upload, and local cleanup of the container
    #
    # @param image_id [String] The name of the docker image
    def push_docker_image(image_id)
      docker_bin = which('docker')
      raise "docker_push: no docker binary: #{image_id}" unless docker_bin
      stdout, stderr, status = Open3.capture3(docker_bin, 'push', image_id)
      raise "stdout: #{stdout}\nstderr: #{stderr}\nstatus: #{status}" \
        unless status.exitstatus.zero?
      clean_up_image(image_id)
    end

    private

    def generate_build_args_json(build_args)
      %w[HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy
         no_proxy].each do |arg|
        build_args[arg] = ENV[arg] if ENV[arg]
      end

      JSON.dump(build_args)
    end

    def populate_args_hash(image_id, build_args_json, dockerfile)
      {
        'nocache' => 'true',
        'pull' => 'true',
        't' => image_id,
        'dockerfile' => dockerfile,
        'buildargs' => build_args_json
      }
    end

    def build_image(build_context, args, timeout)
      ::Docker.options = {
        timeout: timeout,
        read_timeout: timeout,
        write_timeout: timeout
      }
      ::Docker::Image.build_from_dir(build_context, args) do |value|
        build_output(value)
      end
    end
  end
end
