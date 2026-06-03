# frozen_string_literal: true

module PaperTrail
  # mongo_trails captures paper_trail state (whodunnit + accumulated changes) on the saved
  # instance via after_save (see ModelConfig#paper_trail_accumulate_versions), then reads it
  # back from after_commit to build the version (RecordTrail#assign_whodunnit!).
  #
  # When the same record is saved more than once in a transaction through different
  # in-memory instances, Rails 7.1+ picks ONE instance to fire after_commit on and discards
  # the rest — so any state captured on the discarded instance (e.g. inside a
  # `PaperTrail.request.with(whodunnit: ...)` block) is lost.
  #
  # Rails' built-in fix propagates `_new_record_before_last_commit` from the earlier
  # candidate to the later one (active_record/connection_adapters/abstract/transaction.rb).
  # We mirror that for paper_trail state, in the opposite direction: when
  # `run_commit_callbacks_on_first_saved_instances_in_transaction = true` causes Rails to
  # KEEP the earlier candidate and DROP a later instance, copy the later instance's
  # `@paper_trail_whodunnit` and merge its `@paper_trail_accumulated_versions` onto the
  # kept candidate before discarding it.
  module CallbackPropagation
    private

    def prepare_instances_to_run_callbacks_on(records)
      records.each_with_object({}) do |record, candidates|
        next unless record.trigger_transactional_callbacks?

        earlier_saved_candidate = candidates[record]

        if earlier_saved_candidate && record.class.run_commit_callbacks_on_first_saved_instances_in_transaction
          copy_paper_trail_state(from: record, to: earlier_saved_candidate)
          next
        end

        next if earlier_saved_candidate&.destroyed? && !record.destroyed?

        record._new_record_before_last_commit = true if earlier_saved_candidate&._new_record_before_last_commit

        candidates[record] = record
      end
    end

    def copy_paper_trail_state(from:, to:)
      return unless from.respond_to?(:paper_trail_whodunnit) && to.respond_to?(:paper_trail_whodunnit)

      to.instance_variable_set(:@paper_trail_whodunnit, from.paper_trail_whodunnit) if from.paper_trail_whodunnit

      from_changes = from.paper_trail_accumulated_versions
      return if from_changes.blank?

      existing = to.instance_variable_get(:@paper_trail_accumulated_versions) || {}
      to.instance_variable_set(:@paper_trail_accumulated_versions, existing.merge(from_changes))
    end
  end
end

ActiveSupport.on_load(:active_record) do
  require 'active_record/connection_adapters/abstract/transaction'
  ActiveRecord::ConnectionAdapters::Transaction.prepend(PaperTrail::CallbackPropagation)
end
