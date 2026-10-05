# frozen_string_literal: true

require_relative "lib/zabbix_manager/version"

Gem::Specification.new do |spec|
  spec.add_dependency "activesupport", ">= 7.2"
  spec.add_dependency "bigdecimal"
  spec.add_dependency "json", ">= 2.0"
  spec.add_dependency "logger", ">= 1.4"
  spec.add_dependency "net-http"

  spec.name    = "zabbix_manager"
  spec.version = ZabbixManager::VERSION
  spec.authors = ["gatework"]
  spec.email   = ["careline@foxmail.com"]

  spec.summary     = "Ruby client and monitoring workflows for the Zabbix 4.0 through 7.x API"
  spec.description = "A reusable Zabbix API client with device and network-interface monitoring workflows."
  spec.homepage    = "https://github.com/gatework/zabbix_manager/tree/master"
  spec.licenses    = "MIT"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/gatework/zabbix_manager"
  spec.metadata["changelog_uri"]   = "https://github.com/gatework/zabbix_manager/blob/master/CHANGELOG.md"

  spec.files                 = %w[CHANGELOG.md LICENSE README.md zabbix_manager.gemspec] + Dir["lib/**/*.rb"]
  spec.require_paths         = "lib"
  spec.required_ruby_version = ">= 3.4"
end
