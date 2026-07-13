module SketchDraw
  module PdfExport
    ATTR_NS = SketchDraw::PLUGIN_ID

    def self.run
      return unless SketchDraw.version_ok?

      model = Sketchup.active_model
      frame = PaperFrame.find_frame(model)

      unless frame
        UI.messagebox(
          'No paper frame found.\nPlease insert a paper frame first (Paper button).',
          MB_OK
        )
        return
      end

      path = UI.savepanel('Export PDF', '', 'PDF Files|*.pdf||')
      return unless path
      path = "#{path}.pdf" unless path.downcase.end_with?('.pdf')

      w = frame.get_attribute(ATTR_NS, 'width').to_f
      h = frame.get_attribute(ATTR_NS, 'height').to_f

      saved = save_camera(model)

      begin
        setup_export_camera(model, w, h)
        do_export(model, path, w, h)
      ensure
        restore_camera(model, saved)
      end

      UI.messagebox("PDF exported successfully:\n#{path}", MB_OK)
    end

    private

    def self.setup_export_camera(model, width, height)
      view   = model.active_view
      camera = view.camera

      camera.perspective = false

      cx = width  / 2.0
      cy = height / 2.0
      camera.set(
        Geom::Point3d.new(cx, cy, 2000),
        Geom::Point3d.new(cx, cy, 0),
        Geom::Vector3d.new(0, 1, 0)
      )

      bb = Geom::BoundingBox.new
      bb.add(Geom::Point3d.new(-1,        -1,         0))
      bb.add(Geom::Point3d.new(width + 1, height + 1, 0))
      view.zoom(bb)
    end

    def self.do_export(model, path, width, height)
      ver = Sketchup.version.to_f

      if ver >= 25
        options = {
          show_component_axes:       false,
          output_profile_lines:      true,
          output_section_lines:      true,
          generate_nonprofile_lines: true,
          line_width:                0.5,
          line_width_by_layer:       true,
          model_units:               Length::Millimeter
        }
      else
        options = {
          show_component_axes:       false,
          output_profile_lines:      true,
          output_section_lines:      true,
          generate_nonprofile_lines: true,
          line_width:                0.5,
          line_width_by_layer:       true
        }
      end

      model.export(path, options)
    end

    def self.save_camera(model)
      cam = model.active_view.camera
      {
        eye:         cam.eye.clone,
        target:      cam.target.clone,
        up:          cam.up.clone,
        perspective: cam.perspective?
      }
    end

    def self.restore_camera(model, saved)
      cam = model.active_view.camera
      cam.set(saved[:eye], saved[:target], saved[:up])
      cam.perspective = saved[:perspective]
    end
  end
end
