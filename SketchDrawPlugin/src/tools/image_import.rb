module SketchDraw
  module ImageImport
    ATTR_NS = SketchDraw::PLUGIN_ID

    def self.run
      return unless SketchDraw.version_ok?

      path = UI.openpanel(
        'Select Image', '',
        'Image Files|*.jpg;*.jpeg;*.png;*.bmp;*.tif;*.tiff||'
      )
      return unless path && File.exist?(path)

      set_max_texture_size(4096)

      model    = Sketchup.active_model
      entities = model.active_entities
      model.start_operation('Import Image', true)

      width  = default_width_mm(path)
      origin = Geom::Point3d.new(0, 0, 0.5.mm)

      img = entities.add_image(path, origin, width.mm)
      img.set_attribute(ATTR_NS, 'type',       'image')
      img.set_attribute(ATTR_NS, 'orig_path',  path)
      img.set_attribute(ATTR_NS, 'orig_width', width)

      model.commit_operation

      UI.messagebox(
        "Image imported.\n\n" \
        "Tip: Select and use SketchUp's Scale tool to resize it.\n" \
        "Original file is saved for high-quality PDF export."
      )
    end

    private

    def self.set_max_texture_size(size)
      Sketchup.write_default('OpenGL', 'MaxTextureSize', size)
    rescue => e
      puts "[SketchDraw] Could not set MaxTextureSize: #{e.message}"
    end

    def self.default_width_mm(path)
      if Sketchup.version.to_f >= 18
        begin
          rep = Sketchup::ImageRep.new
          rep.load_file(path)
          return 100.0
        rescue => e
          puts "[SketchDraw] ImageRep error: #{e.message}"
        end
      end
      100.0
    end
  end
end
