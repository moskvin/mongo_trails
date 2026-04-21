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
        attr_reader :paper_trail_accumulated_versions

        after_save :paper_trail_accumulate_versions
        after_rollback :paper_trail_clear_accumulated_versions

        private

        def paper_trail_accumulate_versions
          @paper_trail_accumulated_versions ||= {}
          saved_changes.each do |k, v|
            @paper_trail_accumulated_versions[k.to_sym] = v
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
          paper_trail.record_create if paper_trail.save_version?
          paper_trail_clear_accumulated_versions
        end
      end

      append_option_uniquely(:on, :create)
    end

    def on_update
      @model_class.class_eval do
        before_save :paper_trail_reset_timestamps_if_needed
        after_commit :paper_trail_on_record_update, on: :update

        private

        def paper_trail_reset_timestamps_if_needed
          paper_trail.reset_timestamp_attrs_for_update_if_needed
        end

        def paper_trail_on_record_update
          if paper_trail.save_version?
            paper_trail.record_update(
              force: false,
              in_after_callback: true,
              is_touch: false
            )
          end

          paper_trail.clear_version_instance
          paper_trail_clear_accumulated_versions
        end
      end

      append_option_uniquely(:on, :update)
    end
  end
end
