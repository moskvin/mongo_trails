# frozen_string_literal: true

require 'test_helper'

module PaperTrail
  module Events
    # Simulate subclass inheritance
    class Create < Base; end
    class Update < Base; end
    class Destroy < Base; end
  end
end

# Dummy ActiveRecord model that responds to paper_trail_accumulated_versions
# --- The Test Suite ---
class DummyModelWithAccumulated
  attr_accessor :changes, :saved_changes

  def paper_trail_accumulated_versions
    { 'title' => ['Draft', 'Published'] }
  end
end

# Dummy ActiveRecord model missing paper_trail_accumulated_versions
class DummyModelStandard
  attr_accessor :changes, :saved_changes
end

class PaperTrailEventsBaseTest < Minitest::Test
  def setup
    @user = User.new
    @user.instance_variable_set('@paper_trail_accumulated_versions', {
                                  'title' => %w[Draft Published]
    })
    @record_with_accumulated = DummyModelWithAccumulated.new
    @record_standard = DummyModelStandard.new
  end

  def test_uses_accumulated_versions_on_create
    event = PaperTrail::Events::Create.new(@record_with_accumulated, true)
    result = event.load_changes_in_latest_version

    assert_equal({ 'title' => ['Draft', 'Published'] }, result)
  end

  def test_uses_accumulated_versions_on_update
    event = PaperTrail::Events::Update.new(@record_with_accumulated, true, false, nil)
    result = event.load_changes_in_latest_version

    assert_equal({ 'title' => %w[Draft Published] }, result)
  end
  #
  def test_falls_back_if_record_does_not_respond_to_accumulated_versions
    @record_standard.saved_changes = { 'name' => ['Old', 'New'] }
    event = PaperTrail::Events::Update.new(@record_standard, true, false, nil)
    result = event.load_changes_in_latest_version
    assert_equal({ 'name' => ['Old', 'New'] }, result)
  end
  
  def test_uses_saved_changes_when_in_after_callback
    @record_standard.saved_changes = { 'status' => ['Pending', 'Active'] }
    @record_standard.changes = { 'should_ignore' => [1, 2] }

    # Event is Destroy (not Create/Update) so it skips the first IF branch
    event = PaperTrail::Events::Destroy.new(@record_standard, true)

    result = event.load_changes_in_latest_version
    assert_equal({ 'status' => ['Pending', 'Active'] }, result)
  end
  #
  def test_uses_standard_changes_as_default_fallback
    @record_standard.changes = { 'score' => [10, 20] }

    event = PaperTrail::Events::Destroy.new(@record_standard, false)

    result = event.load_changes_in_latest_version
    assert_equal({ 'score' => [10, 20] }, result)
  end
  
  def test_filters_out_unmodified_jsonb_columns
    @record_standard.changes = {
      'valid_change' => ['Old String', 'New String'],
      'jsonb_no_change' => [{ 'key' => 'val' }, { 'key' => 'val' }],
      'jsonb_actual_change' => [{ 'key' => 'val' }, { 'key' => 'new_val' }]
    }

    event = PaperTrail::Events::Destroy.new(@record_standard, false)
    result = event.load_changes_in_latest_version

    assert_includes result.keys, 'valid_change'
    assert_includes result.keys, 'jsonb_actual_change'
    refute_includes result.keys, 'jsonb_no_change', 'Identical JSONB hashes should be filtered out'
  end
end
