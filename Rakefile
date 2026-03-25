# frozen_string_literal: true

require 'bundler/setup'
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib'
  t.libs << 'test'
  t.pattern = 'test/test_*.rb'
  t.warning = true
end

task default: :test
