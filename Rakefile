# frozen_string_literal: true

require 'bundler/setup'
require 'rubygems/package'
require 'rubygems/package_task'
require 'rake/testtask'

gemspec_path = File.expand_path('codex-notify.gemspec', __dir__)
gemspec = Gem::Specification.load(gemspec_path)
raise 'failed to load codex-notify.gemspec' unless gemspec

Gem::PackageTask.new(gemspec).define
Rake::Task[File.join('pkg', gemspec.file_name)].enhance([gemspec_path])

desc 'Build the gem and print its packaged file list'
task 'package:contents' => :gem do
  package_path = File.join('pkg', "#{gemspec.full_name}.gem")
  Gem::Package.new(package_path.to_s).contents.sort.each { |path| puts path }
end

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib'
  t.libs << 'test'
  t.pattern = 'test/test_*.rb'
  t.warning = true
end

task default: :test
