# frozen_string_literal: true

module PaperTrail
  class ModelConfig
    def define_has_many_versions(options)
      options = ensure_versions_option_is_hash(options)
      check_version_class_name(options)
      check_versions_association_name(options)

      @model_class.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def #{@model_class.versions_association_name}
          #{@model_class.version_class_name.constantize}
            .where(item_type: #{@model_class}).and(item_id: self.id).order(created_at: :asc)
        end
      RUBY
    end


    alias_method :setup_callbacks, :setup_callbacks_from_options

    def setup_callbacks_from_options(options)
      on_save
      setup_callbacks(options)
    end

    def on_save
      @model_class.class_eval do
        attr_reader :paper_trail_accumulated_versions, :paper_trail_whodunnit

        after_save :paper_trail_accumulate_versions
        after_rollback :paper_trail_clear_accumulated_versions

        private

        # Capture the whole PaperTrail.request context (not just whodunnit) on the saved
        # instance. The version is built later at transaction commit (see
        # PaperTrail::CallbackPropagation), by which time the request context that performed the
        # save has been restored, so the context the version is attributed to has to travel on the
        # instance. We snapshot the entire request store rather than named fields, so whatever a
        # host app keeps in PaperTrail.request (whodunnit, controller_info, and any custom keys) is
        # preserved without this gem knowing about app-specific state.
        def paper_trail_accumulate_versions
          @paper_trail_accumulated_versions ||= {}
          @paper_trail_whodunnit = PaperTrail.request.whodunnit
          @paper_trail_request_state = paper_trail_request_snapshot

          saved_changes.each do |k, new_value|
            old_value = @paper_trail_accumulated_versions[k.to_sym]
            @paper_trail_accumulated_versions[k.to_sym] = paper_trail_accumulated_version_value(old_value, new_value)
          end
        end

        # A deep copy of the whole PaperTrail.request store (whodunnit, controller_info and any
        # host-app keys), or nil if this build of PaperTrail doesn't expose the store.
        def paper_trail_request_snapshot
          request = PaperTrail.request
          request.respond_to?(:to_h, true) ? request.send(:to_h) : nil
        end

        # Restore the captured request context for the duration of the version build so that
        # everything reading PaperTrail.request while building the version reflects the writer
        # this version belongs to, rather than whatever the request holds at commit time.
        def paper_trail_within_writer_request
          snapshot = instance_variable_defined?(:@paper_trail_request_state) ? @paper_trail_request_state : nil
          request = PaperTrail.request
          return yield unless snapshot && request.respond_to?(:to_h, true) && request.respond_to?(:set, true)

          previous = request.send(:to_h)
          request.send(:set, snapshot)
          begin
            yield
          ensure
            request.send(:set, previous)
          end
        end

        def paper_trail_accumulated_version_value(old_value, new_value)
          if old_value.present? && old_value.is_a?(Array) && old_value.size > 1 && new_value.is_a?(Array) && new_value.size > 1 # rubocop:disable Layout/LineLength
            [old_value.first, new_value.last]
          else
            new_value
          end
        end

        def paper_trail_clear_accumulated_versions
          @paper_trail_accumulated_versions = nil
        end
      end
    end

    def on_create
      @model_class.class_eval do
        after_commit :paper_trail_on_record_create_in_transaction, on: :create

        private

        def paper_trail_on_record_create_in_transaction
          paper_trail_clear_accumulated_versions
        end
      end

      append_option_uniquely(:on, :create)
    end

    def on_update # rubocop:disable Metrics/MethodLength
      @model_class.class_eval do
        before_save :paper_trail_reset_timestamps_if_needed
        after_commit :paper_trail_on_record_update, on: :update

        private

        def paper_trail_reset_timestamps_if_needed
          paper_trail.reset_timestamp_attrs_for_update_if_needed
        end

        def paper_trail_on_record_update
          paper_trail.clear_version_instance
          paper_trail_clear_accumulated_versions
        end
      end

      append_option_uniquely(:on, :update)
    end

    def on_destroy(_recording_order = 'before')
      @model_class.class_eval do
        after_commit :paper_trail_on_record_destroy_in_transaction, on: :destroy

        private

        def paper_trail_on_record_destroy_in_transaction
          paper_trail_within_writer_request { paper_trail.record_destroy('before') }
          paper_trail_clear_accumulated_versions
        end
      end

      append_option_uniquely(:on, :destroy)
    end
  end
end
