module SketchDraw
  class EditTool
    ATTR_NS = SketchDraw::PLUGIN_ID

    def self.install_observer
      obs = AppObserver.new
      Sketchup.add_observer(obs)
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
