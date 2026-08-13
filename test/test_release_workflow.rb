# frozen_string_literal: true

require 'yaml'
require_relative 'test_helper'

class ReleaseWorkflowTest < Minitest::Test
  WORKFLOW_PATH = ROOT.join('.github/workflows/release.yml')

  def test_workflow_has_only_an_explicit_versioned_dispatch_trigger
    workflow = YAML.safe_load_file(WORKFLOW_PATH, aliases: false)
    trigger = (workflow['on'] || workflow.fetch(true)).fetch('workflow_dispatch')
    version = trigger.fetch('inputs').fetch('version')

    assert_equal true, version.fetch('required')
    assert_equal 'string', version.fetch('type')
    assert_equal({ 'contents' => 'read' }, workflow.fetch('permissions'))
  end

  def test_publish_job_has_approval_permissions_dependencies_and_concurrency
    publish = workflow.fetch('jobs').fetch('publish')

    assert_equal 'release', publish.fetch('environment')
    assert_equal %w[test validate-release], publish.fetch('needs')
    assert_equal({ 'contents' => 'write', 'id-token' => 'write' }, publish.fetch('permissions'))
    assert_equal false, publish.fetch('concurrency').fetch('cancel-in-progress')
    assert_includes publish.fetch('if'), "github.ref == 'refs/heads/main'"
  end

  def test_reviewed_release_notes_are_validated_and_used
    validate = workflow.fetch('jobs').fetch('validate-release').fetch('steps')
    notes_validation = validate.find { |step| step.fetch('name', '') == 'Validate reviewed release notes' }
    refute_nil notes_validation
    assert_includes notes_validation.fetch('run'), '.github/release-notes/v${RELEASE_VERSION}.md'

    publish = workflow.fetch('jobs').fetch('publish').fetch('steps')
    release = publish.find { |step| step.fetch('name', '') == 'Create GitHub Release with checksum' }
    refute_nil release
    assert_includes release.fetch('run'), '.github/release-notes/v${RELEASE_VERSION}.md'
    assert_includes release.fetch('run'), '--notes-file'
    refute_includes release.fetch('run'), '--generate-notes'
  end

  def test_all_external_actions_are_pinned_and_checkout_credentials_are_not_persisted
    uses_steps = workflow.fetch('jobs').values.flat_map { |job| job.fetch('steps') }.select { |step| step.key?('uses') }

    uses_steps.each do |step|
      assert_match(/\A[\w-]+\/[\w-]+@[0-9a-f]{40}\z/, step.fetch('uses'))
    end

    checkout_steps = uses_steps.select { |step| step.fetch('uses').start_with?('actions/checkout@') }
    checkout_steps.each do |step|
      assert_equal false, step.fetch('with').fetch('persist-credentials')
    end
  end

  private

  def workflow
    YAML.safe_load_file(WORKFLOW_PATH, aliases: false)
  end
end
