# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rubygems/package"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)

# Follow runtime dependencies only. Development gems must not make the smoke pass.
def runtime_specs(spec, found = {})
  spec.runtime_dependencies.each do |dependency|
    next if found.key?(dependency.name)

    child = Gem::Specification.find_by_name(dependency.name, dependency.requirement)
    found[child.name] = child
    runtime_specs(child, found)
  end
  found.values
end

def run!(environment, *command, **options)
  output, status = Open3.capture2e(environment, *command, **options)
  abort output unless status.success?
  puts output unless output.empty?
end

Dir.mktmpdir("zabbix-manager-package-") do |directory|
  archive = File.join(directory, "zabbix_manager.gem")
  specification = Dir.chdir(ROOT) do
    spec = Gem::Specification.load("zabbix_manager.gemspec")
    Gem::Package.build(spec, false, false, archive)
    spec
  end
  expected = Dir.chdir(ROOT) { Dir["lib/**/*.rb"].sort }
  packaged = Gem::Package.new(archive).spec.files
  abort "Package source inventory differs" unless packaged.grep(%r{\Alib/}).sort == expected
  abort "Package contains development files" if packaged.any? { |file| file.match?(%r{\A(?:spec|tmp|vendor|\.git)/}) }

  runtime_specs(specification).each do |dependency|
    cache = dependency.cache_file
    abort "Missing cached dependency #{dependency.full_name}; run bundle install first" unless File.file?(cache)
    FileUtils.cp(cache, directory)
  end
  install_directory = File.join(directory, "installed")
  environment = {
    "GEM_HOME" => install_directory, "GEM_PATH" => install_directory,
    "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil,
    "BUNDLE_PATH" => nil
  }
  run!(environment, Gem.ruby, "-S", "gem", "install", "--local", "--no-document", archive, chdir: directory)
  run!(environment, Gem.ruby, "-e", <<~'SMOKE', chdir: directory)
    require "json"
    require "socket"
    require "zabbix_manager"
    loaded = Gem.loaded_specs.fetch("zabbix_manager").full_gem_path
    abort "loaded outside isolated install" unless File.realpath(loaded).start_with?(File.realpath(ENV.fetch("GEM_HOME")) + File::SEPARATOR)
    server = TCPServer.new("127.0.0.1", 0)
    server_thread = Thread.new do
      socket = server.accept
      4.times do
        request_line = socket.gets or raise "missing request"
        headers = {}
        while (line = socket.gets) && line != "\r\n"
          name, value = line.split(":", 2)
          headers[name.downcase] = value.strip
        end
        request = JSON.parse(socket.read(Integer(headers.fetch("content-length"))))
        result = case request.fetch("method")
                 when "apiinfo.version" then "7.4.0"
                 when "host.get"
                   raise "missing authentication" unless headers["authorization"] == "Bearer smoke-token"
                   [{ hostid: "1", host: "smoke" }]
                 when "item.get"
                   [{ itemid: "2", hostid: "1", name: "Traffic", units: "bps", value_type: "3" }]
                 when "history.get"
                   [{ itemid: "2", clock: "150", ns: "0", value: "321" }]
                 else raise "unexpected method"
                 end
        body = JSON.generate(jsonrpc: "2.0", result: result, id: request.fetch("id"))
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
      end
    ensure
      socket&.close
    end
    client = ZabbixManager.from_env(
      env: { "ZABBIX_URL" => "http://127.0.0.1:#{server.addr[1]}/api_jsonrpc.php", "ZABBIX_API_TOKEN" => "smoke-token" },
      allow_insecure_http: true, no_proxy: true, timeout: 5
    )
    abort "resource cache mismatch" unless client.hosts.equal?(client.hosts)
    abort "wrong API result" unless client.hosts.get_raw(output: %w[hostid host]).first.fetch("hostid") == "1"
    abort "monitoring is missing" unless client.monitoring.is_a?(ZabbixManager::Monitoring)
    abort "proxy groups are missing" unless client.proxy_groups.is_a?(ZabbixManager::ProxyGroups)
    series = client.traffic.series(hostid: 1, itemids: [2], time_from: 100, time_till: 200)
    item = series.fetch(:series).fetch(0)
    abort "traffic query failed" unless item[:status] == :ok && item[:current_value] == 321 && item[:points].size == 1
    client.close
    raise "server did not finish" unless server_thread.join(10)
    server_thread.value
    server.close
    puts "Isolated installed-gem authentication, resource, monitoring and traffic smoke passed"
  SMOKE
  output = File.join(ROOT, "pkg", "#{specification.full_name}.gem")
  FileUtils.mkdir_p(File.dirname(output))
  FileUtils.cp(archive, output)
  puts "Verified artifact: #{output}"
end
