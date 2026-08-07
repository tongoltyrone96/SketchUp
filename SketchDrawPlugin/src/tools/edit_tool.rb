module SketchDraw
  class EditTool
    ATTR_NS = SketchDraw::PLUGIN_ID

    def self.install_observer
      # Register on the model that is already open when the plugin loads
      if Sketchup.active_model
        Sketchup.active_model.add_observer(ModelObserver.new)
        puts 'SketchDraw: ModelObserver registered on current model'
      end
      # Register AppObserver so future models also get an observer
      Sketchup.add_observer(AppObserver.new)
      puts 'SketchDraw: AppObserver registered'
    end

    class AppObserver < Sketchup::AppObserver
      def onNewModel(model)
        register(model)
      end

      def onOpenModel(model)
        register(model)
      end

      def register(model)
        obs = ModelObserver.new
        model.add_observer(obs)
      end
    end

    class ModelObserver < Sketchup::ModelObserver
      def initialize
        @handling = false
      end

      def onActivePathChanged(model)
        return if @handling

        path = model.active_path
        return if path.nil? || path.empty?

        entity = path.last
        return unless entity.respond_to?(:get_attribute)

        type = entity.get_attribute(SketchDraw::PLUGIN_ID, 'type')
        return unless %w[text arrow].include?(type)

        @handling = true
        UI.start_timer(0.0, false) do
          begin
            model.close_active
            sel = model.selection
            sel.clear
            sel.add(entity)
            EditTool.edit_selected
          ensure
            @handling = false
          end
        end
      end
    end

    def self.edit_selected
      model     = Sketchup.active_model
      selection = model.selection
      return if selection.empty?

      entity = selection.first
      return unless entity.respond_to?(:get_attribute)

      type = entity.get_attribute(ATTR_NS, 'type')
      case type
      when 'text'
        TextTool.show_dialog(entity)
      when 'arrow'
        ArrowTool.show_edit_dialog(entity)
      when 'dimension'
        edit_dimension(entity)
      end
    end

    def self.edit_dimension(dim_entity)
      return unless dim_entity.is_a?(Sketchup::DimensionLinear)
      raw   = dim_entity.get_attribute(ATTR_NS, 'raw_dist', 0).to_f
      ratio = UI.inputbox(['Scale ratio:'], [State.scale_ratio], 'Edit Dimension')
      return unless ratio
      new_ratio       = ratio[0].to_i
      dim_entity.text = format_mm(raw * new_ratio)
      dim_entity.set_attribute(ATTR_NS, 'scale', new_ratio)
    end

    def self.format_mm(mm)
      mm >= 1000 ? format('%.2fm', mm / 1000.0) : format('%.0fmm', mm)
    end
  end
end
