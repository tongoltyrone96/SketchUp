module SketchDraw
  module Lock2D
    @saved_camera = nil

    def self.toggle
      State.lock_2d ? deactivate : activate
    end

    def self.activate
      model  = Sketchup.active_model
      view   = model.active_view
      camera = view.camera

      @saved_camera = {
        eye:         camera.eye.clone,
        target:      camera.target.clone,
        up:          camera.up.clone,
        perspective: camera.perspective?
      }

      set_top_view(model, view)

      obs = TwoDViewObserver.new
      view.add_observer(obs)
      State.lock_observer = obs
      State.lock_2d       = true

      Sketchup.set_status_text('  ★ 2D Lock ON — orbit disabled. Click 2D button to unlock.')
    end

    def self.deactivate
      model = Sketchup.active_model
      view  = model.active_view

      if State.lock_observer
        view.remove_observer(State.lock_observer)
        State.lock_observer = nil
      end

      if @saved_camera
        cam = view.camera
        cam.set(@saved_camera[:eye], @saved_camera[:target], @saved_camera[:up])
        cam.perspective = @saved_camera[:perspective]
        @saved_camera = nil
      else
        view.camera.perspective = true
      end

      State.lock_2d = false
      Sketchup.set_status_text('')
    end

    # ── Private helpers ───────────────────────────────────────────────

    def self.set_top_view(model, view)
      frame = PaperFrame.find_frame(model)
      if frame && frame.valid?
        w = frame.get_attribute(SketchDraw::PLUGIN_ID, 'width').to_f
        h = frame.get_attribute(SketchDraw::PLUGIN_ID, 'height').to_f
        # Set camera first, then zoom — avoids timing issue with view.zoom
        cam = view.camera
        cam.perspective = false
        cam.set(
          Geom::Point3d.new(w / 2.0, h / 2.0, 1000),
          Geom::Point3d.new(w / 2.0, h / 2.0, 0),
          Geom::Vector3d.new(0, 1, 0)
        )
        view.zoom(frame)
      else
        bb  = model.bounds
        cx  = bb.valid? ? bb.center.x : 0
        cy  = bb.valid? ? bb.center.y : 0
        cam = view.camera
        cam.perspective = false
        cam.set(
          Geom::Point3d.new(cx, cy, 2000),
          Geom::Point3d.new(cx, cy, 0),
          Geom::Vector3d.new(0, 1, 0)
        )
        view.zoom_extents
      end
    end
    private_class_method :set_top_view

    # ── View observer — snaps back to top view on any orbit ──────────
    class TwoDViewObserver < Sketchup::ViewObserver
      def initialize
        @resetting = false
      end

      def onViewChanged(view)
        return unless State.lock_2d
        return if @resetting

        cam = view.camera
        looking_down = cam.direction.z.abs > 0.999
        up_correct   = cam.up.dot(Geom::Vector3d.new(0, 1, 0)) > 0.999
        return if looking_down && up_correct

        @resetting = true
        eye = cam.eye
        h   = eye.z > 10 ? eye.z : 2000
        cam.set(
          Geom::Point3d.new(eye.x, eye.y, h),
          Geom::Point3d.new(eye.x, eye.y, 0),
          Geom::Vector3d.new(0, 1, 0)
        )
        cam.perspective = false
        @resetting = false
      end
    end
  end
end
