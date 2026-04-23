module PaperTrail
  module Events
    class Base
      def load_changes_in_latest_version
        changes = if ['PaperTrail::Events::Create', 'PaperTrail::Events::Update'].include?(self.class.to_s) && @record.respond_to?(:paper_trail_accumulated_versions)
          @record.paper_trail_accumulated_versions
        elsif @in_after_callback
          @record.saved_changes
        else
          @record.changes
        end

        safe_changes = changes ? changes.dup : {}

        safe_changes.delete_if do |_k, v|
          next unless v.is_a?(Array)
          next if v.size <= 1

          v.uniq.size == 1
        end
        
        safe_changes
      end
    end
  end
end
