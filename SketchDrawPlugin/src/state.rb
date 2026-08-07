module SketchDraw
  module State
    @scale_ratio        = 1
    @lock_2d            = false
    @lock_observer      = nil
    @native_dim_observer = nil

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

      def install_native_dim_observer(model)
        return if @native_dim_observer
        @native_dim_observer = NativeDimObserver.new
        model.active_entities.add_observer(@native_dim_observer)
      end

      def remove_native_dim_observer(model)
        return unless @native_dim_observer
        model.active_entities.remove_observer(@native_dim_observer) rescue nil
        @native_dim_observer = nil
      end

      def reset
        @scale_ratio         = 1
        @lock_2d             = false
        @lock_observer       = nil
        @native_dim_observer = nil
      end

      # True when the user is currently editing a paper frame group
      # (via double-click into it). Text / Arrow / Section tools use this
      # to decide whether their paper-mm sizes should be used as-is (inside
      # a frame) or scaled up to be visible at world scale (outside a
      # frame — e.g. dropped directly onto a metre-scale scaffold model).
      def inside_paper_frame?(model = Sketchup.active_model)
        return false unless model
        path = model.active_path
        return false if path.nil?
        arr = path.respond_to?(:to_a) ? path.to_a : [path]
        return false if arr.empty?
        arr.any? do |g|
          begin
            g.get_attribute(SketchDraw::PLUGIN_ID, 'type') == 'paper_frame'
          rescue
            false
          end
        end
      rescue
        false
      end

      # Returns a multiplier that scales paper-millimetre sizes so they
      # stay visible at the current view zoom. Inside a paper frame the
      # multiplier is 1.0 (paper mm is exactly what we want on paper). At
      # world scale — e.g. dropped onto a 17-metre scaffold at 1:1 — a
      # 3.5mm text height is sub-pixel and invisible; here we return the
      # ratio between "1 paper mm at current view zoom" and the actual
      # 1mm world unit. The multiplier is never less than 1.0 (we never
      # shrink), and never used when SketchUp can't tell us the pixel
      # scale (returns 1.0 defensively).
      #
      # `point` is the placement point in world coords — needed because in
      # perspective views the pixels-per-world-unit ratio depends on depth.
      def paper_scale_multiplier_at(model = Sketchup.active_model, point = nil)
        return 1.0 unless model
        return 1.0 if inside_paper_frame?(model)
        view = model.active_view
        return 1.0 unless view
        pt = point || model.bounds.center
        world_per_pixel = begin
          view.pixels_to_model(1, pt).to_f
        rescue
          0.0
        end
        return 1.0 if world_per_pixel <= 0
        # 1mm on paper ≈ 3.78 pixels at typical 96 DPI display, so 1 paper
        # mm should look ~3.78 pixels wide in the viewport for readability.
        target_world_per_paper_mm = world_per_pixel * 3.78
        paper_1mm_su = 1.0.mm  # SU internal length unit is inches
        mult = target_world_per_paper_mm / paper_1mm_su
        mult < 1.0 ? 1.0 : mult
      rescue
        1.0
      end
    end
  end
end
