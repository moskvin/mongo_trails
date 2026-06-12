# frozen_string_literal: true

module PaperTrail
  # mongo_trails captures paper_trail state on each saved instance via after_save (see
  # ModelConfig#paper_trail_accumulate_versions): that instance's accumulated field changes plus
  # a snapshot of the whole PaperTrail.request context at save time.
  #
  # The version is built HERE, from `prepare_instances_to_run_callbacks_on`, which Rails calls
  # once per transaction commit. We build one version per distinct in-memory instance that
  # accumulated changes, restoring that instance's captured request context while the version is
  # built — so the version is attributed to the writer that performed the save (e.g. the specific
  # automation), not to whatever the request happens to hold at commit time.
  #
  # Building per instance (rather than once per record) is deliberate: when several writers each
  # load and save the record through their OWN instance in one transaction — the common
  # multi-automation pattern, including the same set of automations firing again — each writer
  # gets its own, correctly-attributed version. Rails 7.1+ fires after_commit on only ONE instance
  # per record (`run_commit_callbacks_on_first_saved_instances_in_transaction`), so building from
  # after_commit would lose the others; `prepare_instances_to_run_callbacks_on` sees every
  # instance (`unique_records` is de-duplicated by object identity, not by record identity).
  #
  # Non-ActiveRecord objects enrolled in the transaction by other gems (e.g.
  # after_commit_everywhere's Wrap) are ignored: `merge_accumulated_versions` only acts on objects
  # exposing `paper_trail_accumulated_versions`, and the Rails dedup branch only reads the AR-only
  # `run_commit_callbacks_on_first_saved_instances_in_transaction` class attribute when there is an
  # earlier candidate of the same record (never the case for unique Wrap objects).
  module CallbackPropagation
    private

    def prepare_instances_to_run_callbacks_on(records)
      records.each_with_object({}) do |record, candidates|
        next unless record.trigger_transactional_callbacks?

        earlier_saved_candidate = candidates[record]

        # Build this instance's version once the transaction has actually committed. Each
        # distinct instance gets its own version, attributed to the context captured while it
        # was saved. Skipped on rollback (`@state.committed?` is false).
        merge_accumulated_versions(from: record) if @state.committed?

        next if earlier_saved_candidate && record.class.run_commit_callbacks_on_first_saved_instances_in_transaction
        next if earlier_saved_candidate&.destroyed? && !record.destroyed?

        record._new_record_before_last_commit = true if earlier_saved_candidate&._new_record_before_last_commit

        candidates[record] = record
      end
    end

    def merge_accumulated_versions(from:)
      return unless from.respond_to?(:paper_trail_accumulated_versions)

      from_changes = from.paper_trail_accumulated_versions
      return if from_changes.blank?

      from.send(:paper_trail_within_writer_request) do
        # Mirror Rails' own create-vs-update determination for after_commit callbacks
        # (ActiveRecord::Transactions#transaction_include_any_action?): a record created in this
        # transaction is a `create` even if it was updated again afterwards. `previously_new_record?`
        # only reflects the LAST save, so it mislabels create-then-update-in-one-transaction as an
        # update; `_new_record_before_last_commit` is the transaction-aware flag Rails uses.
        if from.persisted? && from._new_record_before_last_commit
          from.paper_trail.record_create if from.paper_trail.save_version?
        elsif from.paper_trail.save_version?
          from.paper_trail.record_update(force: false, in_after_callback: true, is_touch: false)
        end
      end
    end
  end
end

ActiveSupport.on_load(:active_record) do
  require 'active_record/connection_adapters/abstract/transaction'

  # `prepare_instances_to_run_callbacks_on` and the
  # `run_commit_callbacks_on_first_saved_instances_in_transaction` class attribute were
  # introduced together in Rails 7.1. On older Rails the dedup logic is inline in
  # `commit_records` and not configurable — skip the prepend so we don't shadow a method
  # the gem doesn't need and don't reference a missing class attribute.
  if ActiveRecord::ConnectionAdapters::Transaction.private_method_defined?(:prepare_instances_to_run_callbacks_on)
    ActiveRecord::ConnectionAdapters::Transaction.prepend(PaperTrail::CallbackPropagation)
  end
end
