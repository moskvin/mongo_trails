module PaperTrail
  module Events
    class Base
      def load_changes_in_latest_version
        changes = if ['PaperTrail::Events::Create', 'PaperTrail::Events::Update'].include?(self.class.to_s)
          @record.paper_trail_accumulated_versions
        elsif @in_after_callback
          @record.saved_changes
        else
          @record.changes
        end

        changes = @record.paper_trail_accumulated_versions 

        # this is for checking the change in a jsonb column
        changes.delete_if { |_k, v|
          v.is_a?(Array) && v.size > 1 && v.last.is_a?(Hash) && v.uniq.size == 1
        }
        changes
      end
    end
  end
end
