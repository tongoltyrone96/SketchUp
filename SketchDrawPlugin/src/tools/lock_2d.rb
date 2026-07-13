module SketchDraw
  module Lock2D
    ATTR_NS = SketchDraw::PLUGIN_ID

    def self.toggle
      if State.lock_2d
        deactivate
      else
        activate
      end
    end

    def self.activate
      model = Sketchup.active_model
      view  = model.active_view

      view.camera.perspective = false

      obs = TwoDViewObserver.new
      view.add_observer(obs)
      State.lock_observer = obs
      State.lock_2d       = true

      Sketchup.set_status_text('2D Lock ON — 3D rotation disabled. Click 2D button to unlock.')
    end

    def self.deactivate
      model = Sketchup.active_model
      view  = model.active_view

      if State.lock_observer
        view.remove_observer(State.lock_observer)
        State.lock_observer = nil
      end

      view.camera.perspective = true
      State.lock_2d = false
      Sketchup.set_status_text('')
    end

    class TwoDViewObserver < Sketchup::ViewObserver
      def onViewChanged(view)
        return unless State.lock_2d
        camera = view.camera

        dir    = camera.direction
        is_top = dir.z.abs > 0.95

        unless is_top
          eye     = camera.eye
          new_eye = Geom::Point3d.new(eye.x, eye.y, 2000)
          target  = Geom::Point3d.new(eye.x, eye.y, 0)
          up      = Geom::Vector3d.new(0, 1, 0)
          camera.set(new_eye, target, up)
          camera.perspective = false
        end
      end
    end
  end
end
