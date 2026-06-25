# frozen_string_literal: true

require 'test_helper'

class TransactionHandlingTest < Minitest::Test
  def setup
    PaperTrail.request.whodunnit = 'Andy Stewart'
    PaperTrail.config.enable_sidekiq = false
    [User, Comment].map(&:delete_all)
    Mongoid.purge!
  end

  def test_on_update_creates_version_if_transaction_completed
    user = User.create!(name: 'John Doe')
    assert_equal 1, user.versions.count

    ActiveRecord::Base.transaction do
      user.update!(name: 'Arnold Schwarzenegger')
    end

    assert_equal 2, user.versions.count
  end

  def test_on_update_many_versions_for_many_updates
    user = User.create!(name: 'John Doe')
    assert_equal 1, user.versions.count

    ActiveRecord::Base.transaction do
      user.update!(name: 'Arnold Schwarzenegger')
      user.update!(title: 'Governor')
      user.update!(name: 'Chuck Norris')
      user.update!(name: 'Jackie Chan')
    end

    assert_equal 2, user.versions.count
    assert_equal %w[create update], user.versions.pluck(:event)
    versions = user.versions
    assert_equal(versions.last.event, 'update')
    assert_equal(versions.last.object_changes.keys, %w[name title])
    assert_equal(['John Doe', 'Jackie Chan'], versions.last.object_changes['name'])
    assert_equal([nil, 'Governor'], versions.last.object_changes['title'])
  end

  def test_on_update_that_did_not_changed_the_name
    user = User.create!(name: 'John Doe')
    assert_equal 1, user.versions.count

    ActiveRecord::Base.transaction do
      user.update!(name: 'Jackie Chan')
      user.update!(name: 'Chuck Norris')
      user.update!(name: 'John Doe')
    end

    assert_equal ['create'], user.versions.pluck(:event)
    assert_equal 1, user.versions.count
    assert_equal 'create', user.versions.first.event
  end

  def test_on_name_not_changed_but_title_changed
    user = User.create!(name: 'John Doe')
    assert_equal 1, user.versions.count

    ActiveRecord::Base.transaction do
      user.update!(name: 'Jackie Chan')
      user.update!(title: 'Governor')
      user.update!(name: 'John Doe')
    end

    assert_equal 2, user.versions.count
    assert_equal %w[create update], user.versions.pluck(:event)
    versions = user.versions
    assert_equal(versions.last.event, 'update')
    assert_equal(versions.last.object_changes.keys, %w[title])
    assert_equal([nil, 'Governor'], versions.last.object_changes['title'])
  end

  # When the same record is written through SEVERAL distinct in-memory instances in one
  # transaction (e.g. several automations each loading and updating it), each instance produces
  # its own version, attributed to the context captured while that instance was saved — rather
  # than collapsing every change onto a single version.
  def test_distinct_instances_each_get_their_own_version
    user = User.create!(name: 'John Doe')
    assert_equal 1, user.versions.count

    ActiveRecord::Base.transaction do
      User.find(user.id).update!(name: 'Jackie Chan')
      User.find(user.id).update!(title: 'Governor')
    end

    assert_equal 3, user.versions.count
    assert_equal %w[create update update], user.versions.pluck(:event)
    updates = user.versions.where(event: 'update').to_a
    assert(updates.any? { |v| v.object_changes.keys == %w[name] })
    assert(updates.any? { |v| v.object_changes.keys == %w[title] })
  end

  def test_on_update_does_not_create_version_if_transaction_not_completed
    user = User.create!(name: 'John Doe')
    assert_equal 1, user.versions.count

    ActiveRecord::Base.transaction do
      user.update!(name: 'Arnold Schwarzenegger')
      raise ActiveRecord::Rollback
    end

    assert_equal 1, user.versions.count
  end

  def test_on_create_creates_version_if_transaction_completed
    assert_equal 0, MongoTrails::Version.count

    user = nil
    ActiveRecord::Base.transaction do
      user = User.create!(name: 'Arnold Schwarzenegger')
    end

    assert_equal 1, user.versions.count
  end

  def test_on_create_does_not_create_version_if_transaction_not_completed
    assert_equal 0, MongoTrails::Version.count

    ActiveRecord::Base.transaction do
      User.create!(name: 'Arnold Schwarzenegger')
      raise ActiveRecord::Rollback
    end

    assert_equal 0, MongoTrails::Version.count
  end

  def test_on_destroy_creates_version_if_transaction_completed
    user = User.create!(name: 'John Doe')
    assert_equal 1, user.versions.count

    ActiveRecord::Base.transaction do
      user.destroy!
    end

    assert_equal 2, user.versions.count
  end

  def test_on_destroy_does_not_create_version_if_transaction_not_completed
    user = User.create!(name: 'John Doe')
    assert_equal 1, user.versions.count

    ActiveRecord::Base.transaction do
      user.destroy!
      raise ActiveRecord::Rollback
    end

    assert_equal 1, user.versions.count
  end

  # A destroy never fires after_save, so the writer context is not captured by the usual
  # accumulate-on-save path. The destroy version is built at commit time (after_commit on:
  # :destroy), by which point the request context may have moved on. The context must be
  # snapshotted while the record is being destroyed (before_destroy) so the version is still
  # attributed to the writer that destroyed it, not to whatever the request holds at commit time.
  def test_on_destroy_keeps_writer_whodunnit_when_request_changes_before_commit
    PaperTrail.request.whodunnit = 'deleter'
    user = User.create!(name: 'John Doe')

    ActiveRecord::Base.transaction do
      user.destroy!
      # Simulate the writer's context being torn down before the outermost transaction commits
      # (e.g. a service object that resets whodunnit in an ensure block).
      PaperTrail.request.whodunnit = 'someone-else'
    end

    destroy_version = user.versions.where(event: 'destroy').last
    assert_not_nil destroy_version, 'A destroy version should have been created'
    assert_equal 'deleter', destroy_version.whodunnit
  end
end
