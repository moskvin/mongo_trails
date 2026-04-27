require 'test_helper'

class UserWhodunnitTest < ActiveSupport::TestCase
  setup do
    # Ensure PaperTrail is enabled for tests (often turned off by default in test_helper)
    PaperTrail.request.enabled = true
    
    # Create the base record to update
    @user = User.create!(title: 'citizen')
  end

  teardown do
    # Clean up global state so it doesn't leak into other test files
    PaperTrail.request.whodunnit = nil
  end

  test "preserves block whodunnit for versions created inside a transaction" do
    # 1. Set the baseline context
    PaperTrail.request.whodunnit = '4'

    # 2. Execute your specific block structure
    User.transaction do
      # Swap `PaperTrail.request.with` with your custom `Papertrail.with` if you have a wrapper
      PaperTrail.request.with(whodunnit: 'System') do
        @user.update!(title: 'president')
      end
    end

    # 3. Assert the global state successfully reverted back to '4' after the block
    assert_equal '4', PaperTrail.request.whodunnit, "Global whodunnit should revert back to 4"

    # 4. Assert the version correctly captured 'System'
    last_version = @user.versions.last
    
    assert_not_nil last_version, "A PaperTrail version should have been created"
    assert_equal 'System', last_version.whodunnit, "The version whodunnit should be 'System', not '4'"
  end
end
