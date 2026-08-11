# frozen_string_literal: true

require_relative 'lib/codex_notify/version'

Gem::Specification.new do |spec|
  spec.name = 'codex-notify'
  spec.version = CodexNotify::VERSION
  spec.authors = ['Koichiro Ohba']
  spec.email = ['koichiro.ohba@gmail.com']

  spec.summary = 'Send compact Codex activity notifications to Slack'
  spec.description = 'Log-tail and Codex Hook commands that send compact Codex activity notifications to Slack.'
  spec.homepage = 'https://github.com/koichiro/codex-notify'
  spec.license = 'MIT'
  spec.required_ruby_version = Gem::Requirement.new('>= 3.4.0')

  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'bug_tracker_uri' => "#{spec.homepage}/issues"
  }

  spec.files = Dir.chdir(__dir__) do
    (Dir['lib/**/*.rb'] + %w[bin/codex-notify bin/codex-notify-hook LICENSE README.md]).sort
  end
  spec.bindir = 'bin'
  spec.executables = %w[codex-notify codex-notify-hook]
  spec.require_paths = ['lib']

  spec.add_dependency 'dotenv', '~> 3.2'
end
