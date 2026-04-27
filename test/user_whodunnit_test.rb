require 'test_helper'

class UserWhodunnitTest < ActiveSupport::TestCase
  setup do
    PaperTrail.request.enabled = true
    @user = User.create!(title: 'citizen')
  end

  teardown do
    PaperTrail.request.whodunnit = nil
  end

  test "preserves block whodunnit for versions created inside a transaction" do
    PaperTrail.request.whodunnit = '4'

    User.transaction do
      PaperTrail.request.with(whodunnit: 'System') do
        @user.update!(title: 'president')
      end
    end

    assert_equal '4', PaperTrail.request.whodunnit, "Global whodunnit should revert back to 4"
    last_version = @user.versions.last
    assert_not_nil last_version, "A PaperTrail version should have been created"
    assert_equal 'System', last_version.whodunnit, "The version whodunnit should be 'System', not '4'"
  end
end
