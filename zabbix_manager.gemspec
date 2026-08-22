# coding: utf-8
# frozen_string_literal: true

lib = File.expand_path("../lib", __FILE__)

$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require "zabbix_manager/version"

Gem::Specification.new do |spec|
  spec.add_dependency "activesupport", ">= 6.1", "< 8"
  spec.add_dependency "json", "~> 2.0"
  spec.add_dependency "logger", ">= 1.4"
  spec.add_development_dependency "bundler", "~> 2.3", ">= 2.3.9"
  spec.add_development_dependency "base64", ">= 0.2"
  spec.add_development_dependency "benchmark", ">= 0.3"
  spec.add_development_dependency "minitest", "~> 5.27"
  spec.add_development_dependency "ostruct", ">= 0.6"
  spec.add_development_dependency "racc", ">= 1.6"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "yard", "~> 0.9.27"
  spec.add_development_dependency "yardstick", "~> 0.9.9"
  spec.add_development_dependency "rubocop", "~> 1.25", ">= 1.25.1"
  spec.add_development_dependency "rubocop-performance", "~> 1.13"
  spec.add_development_dependency "rubocop-packaging", "~> 0.5.1"

  spec.name    = "zabbix_manager"
  spec.version = ZabbixManager::VERSION
  spec.authors = ["WENWU YAN"]
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
  spec.required_ruby_version = ">= 2.7.0"
end
