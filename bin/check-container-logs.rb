#! /usr/bin/env ruby
#
#   check-container-logs
#
# DESCRIPTION:
#   Checks docker logs for specified strings
#   with the option to ignore lines if they contain specified substrings.
#
# OUTPUT:
#   plain text
#
# PLATFORMS:
#   Linux
#
# DEPENDENCIES:
#   gem: sensu-plugin
#   gem: net_http_unix
#
# USAGE:
#   check-container-logs.rb -H /tmp/docker.sock -n logspout -r 'problem sending' -r 'i/o timeout' -i 'Remark:' -i 'The configuration is'
#   => 1 container running = OK
#   => 4 container running = CRITICAL
#
# NOTES:
#   The API parameter required to use the limited lookback (-t) was introduced
#   the Docker server API version 1.19. This check may still work on older API
#   versions if you don't want to limit the timestamps of logs.
#
# LICENSE:
#   Author: Nathan Newman  <newmannh@gmail.com>, Kel Cecil <kelcecil@praisechaos.com>
#   Released under the same terms as Sensu (the MIT license); see LICENSE
#   for details.
#

require 'sensu-plugin/check/cli'
require 'net_http_unix'

class ContainerLogChecker < Sensu::Plugin::Check::CLI
  option :docker_host,
         description: 'location of docker api: host:port or /path/to/docker.sock',
         short: '-H DOCKER_HOST',
         long: '--docker-host DOCKER_HOST',
         default: '127.0.0.1:2375'

  option :container,
         description: 'name of container',
         short: '-n CONTAINER',
         long: '--container-name CONTAINER',
         required: true

  option :red_flags,
         description: 'substring whose presence (case-insensitive by default) in a log line indicates an error; can be used multiple t
imes',
         short: '-r "error occurred" -r "problem encountered" -r "error status"',
         long: '--red-flag "error occurred" --red-flag "problem encountered" --red-flag "error status"',
         default: [],
         proc: proc { |flag| (@options[:red_flags][:accumulated] ||= []).push(flag) }

  option :ignore_list,
         description: 'substring whose presence (case-insensitive by default) in a log line indicates the line should be ignored; can
be used multiple times',
         short: '-i "configuration:" -i "# Remark:"',
         long: '--ignore-lines-with "configuration:" --ignore-lines-with "# remark:"',
         default: [],
         proc: proc { |flag| (@options[:ignore_list][:accumulated] ||= []).push(flag) }

  option :case_sensitive,
         description: 'indicates all red_flag and ignore_list substring matching should be case-sensitive instead of the default case-
insensitive',
         short: '-c',
         long: '--case-sensitive',
         boolean: true

  option :hours_ago,
        description: 'Amount of time in hours to look back for log strings',
        short: '-t HOURS',
        long: '--hours-ago HOURS',
        required: false

  def calculate_timestamp(hours)
    seconds_ago = hours.to_i * 3600
    return (Time.now - seconds_ago).to_i
  end

  def create_client
    client = nil
    if config[:docker_host][0] == '/'
      host = 'unix://' + config[:docker_host]
      client = NetX::HTTPUnix.new(host)
    else
      split_host = config[:docker_host].split ':'
      if split_host.length == 2
        client = NetX::HTTPUnix.new(split_host[0], split_host[1])
      else
        client = NetX::HTTPUnix.new(config[:docker_host], 2375)
      end
    end

    client
  end

  def process_docker_logs(containerName)
    client = create_client
    path = "/containers/#{containerName}/logs?stdout=true&stderr=true"
    if config.has_key? :hours_ago
      path = "#{path}&since=#{calculate_timestamp config[:hours_ago]}"
    end
    req = Net::HTTP::Get.new path
    client.request req do |response|
      response.read_body do |chunk|
        yield remove_headers chunk
      end
    end
  end

  def remove_headers(raw_logs)
    lines = raw_logs.split("\n")
    lines.map! { |line| line.byteslice(8, line.bytesize) }
    lines.join("\n")
  end

  def includes_any?(str, arrayOfSubstrings)
    arrayOfSubstrings.each do |substring|
      return true if str.include? substring
    end
    false
  end

  def detect_problem(logs)
    whiteflags = config[:ignore_list]
    redflags = config[:red_flags]
    unless config[:case_sensitive]
      logs = logs.downcase
      whiteflags.map!(&:downcase)
      redflags.map!(&:downcase)
    end

    logs.split("\n").each do |line|
      return line if !includes_any?(line, whiteflags) && includes_any?(line, redflags)
    end
    nil
  end

  def run
    container = config[:container]
    process_docker_logs(container) do |log_chunk|
      problem = detect_problem log_chunk
      critical "#{container} container logs indicate problem: '#{problem}'." unless problem.nil?
    end
    ok "No errors detected from #{container} container logs."
  end
end
