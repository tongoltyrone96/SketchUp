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
      Sketchup.active_model.select_tool(ImagePlacementTool.new(path))
    end

    def self.place_image_at(origin, path)
      model    = Sketchup.active_model
      entities = model.active_entities

      width_mm  = 100.0
      height_mm = 75.0
      if defined?(Sketchup::ImageRep)
        begin
          rep = Sketchup::ImageRep.new
          rep.load_file(path)
          height_mm = width_mm * rep.height.to_f / rep.width.to_f if rep.width > 0
        rescue => e
          puts "SketchDraw ImageRep: #{e.message}"
        end
      end

      placed = nil
      model.start_operation('Import Image', true)
      begin
        base     = File.basename(path, '.*').gsub(/[^A-Za-z0-9]/, '_')[0, 24]
        mat_name = "SKD_img_#{base}"
        mat      = model.materials[mat_name] || model.materials.add(mat_name)
        mat.texture      = path
        mat.texture.size = [width_mm.mm, height_mm.mm]

        pt1 = Geom::Point3d.new(origin.x,                  origin.y,                   0)
        pt2 = Geom::Point3d.new(origin.x + width_mm.mm,    origin.y,                   0)
        pt3 = Geom::Point3d.new(origin.x + width_mm.mm,    origin.y + height_mm.mm,    0)
        pt4 = Geom::Point3d.new(origin.x,                  origin.y + height_mm.mm,    0)

        grp  = entities.add_group
        face = grp.entities.add_face([pt1, pt2, pt3, pt4])
        if face
          face.material      = mat
          face.back_material = mat

          # UV mapping: SketchUp uses OpenGL convention — UV(0,0) = bottom-left of texture.
          # pt1=bottom-left → UV(0,0), pt2=bottom-right → UV(1,0), pt4=top-left → UV(0,1)
          uv_map = [
            pt1, Geom::Point3d.new(0, 0, 0),
            pt2, Geom::Point3d.new(1, 0, 0),
            pt4, Geom::Point3d.new(0, 1, 0)
          ]
          face.position_material(mat, uv_map, true)
          face.position_material(mat, uv_map, false)
          face.edges.each { |e| e.hidden = true }
        end

        grp.set_attribute(ATTR_NS, 'type',      'image')
        grp.set_attribute(ATTR_NS, 'orig_path', path)
        grp.name = 'SketchDraw_Image'
        placed   = grp
        model.commit_operation
      rescue => e
        model.abort_operation rescue nil
        puts "SketchDraw ImageImport error: #{e.message}"
        puts e.backtrace.first(3).join("\n")
      end
      placed
    end

    def self.set_max_texture_size(size)
      Sketchup.write_default('OpenGL', 'MaxTextureSize', size)
    rescue => e
      puts "[SketchDraw] Could not set MaxTextureSize: #{e.message}"
    end
    private_class_method :set_max_texture_size
  end

  class ImagePlacementTool
    CURSOR_CROSSHAIR = 641

    def initialize(path)
      @path   = path
      @ip     = Sketchup::InputPoint.new
      @placed = nil
    end

    def activate
      Sketchup.set_status_text('Click to place image — ESC to cancel')
    end

    def onSetCursor
      UI.set_cursor(CURSOR_CROSSHAIR)
    end

    def onMouseMove(_flags, x, y, view)
      @ip.pick(view, x, y)
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      @ip.pick(view, x, y)
      pt      = Geom::Point3d.new(@ip.position.x, @ip.position.y, 0)
      @placed = ImageImport.place_image_at(pt, @path)
      placed  = @placed

      UI.start_timer(0.0, false) do
        model = Sketchup.active_model
        model.select_tool(nil)
        if placed
          model.selection.clear
          model.selection.add(placed)
        end
      end
    end

    def onKeyDown(key, _r, _f, _v)
      Sketchup.active_model.select_tool(nil) if key == 27
    end
  end
end
