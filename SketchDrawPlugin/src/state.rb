module SketchDraw
  module State
    @scale_ratio   = 1
    @lock_2d       = false
    @lock_observer = nil

    class << self
      attr_accessor :scale_ratio, :lock_2d, :lock_observer

      def save_to_model(model = Sketchup.active_model)
        model.set_attribute(SketchDraw::PLUGIN_ID, 'scale_ratio', @scale_ratio)
      end

      def load_from_model(model = Sketchup.active_model)
        @scale_ratio = model.get_attribute(
          SketchDraw::PLUGIN_ID, 'scale_ratio', 1
        ).to_i
      end

      def reset
        @scale_ratio   = 1
        @lock_2d       = false
        @lock_observer = nil
      end
    end
  end
end
