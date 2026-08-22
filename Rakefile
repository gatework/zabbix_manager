# frozen_string_literal: true

require "bundler"
Bundler::GemHelper.install_tasks

require "rspec/core/rake_task"
RSpec::Core::RakeTask.new(:spec)

task test: :spec

require "rubocop/rake_task"
RuboCop::RakeTask.new

require "yard"
YARD::Rake::YardocTask.new

require "yardstick/rake/measurement"
yardstick_options = { rules: { ExampleTag: { enabled: false } } }
Yardstick::Rake::Measurement.new(:yardstick_measure, yardstick_options) do |measurement|
  measurement.output = "measurement/report.txt"
end

require "yardstick/rake/verify"
Yardstick::Rake::Verify.new(:verify_measurements, yardstick_options) do |verify|
  verify.threshold = 67.1
  verify.require_exact_threshold = false
end

task default: [:spec, :rubocop, :verify_measurements]
