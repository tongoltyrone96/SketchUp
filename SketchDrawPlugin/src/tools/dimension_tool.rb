module SketchDraw
  class DimensionTool
    ATTR_NS = SketchDraw::PLUGIN_ID

    def self.activate
      return unless SketchDraw.version_ok?
      Sketchup.active_model.select_tool(new)
    end

    def initialize
      @pts         = []
      @mouse       = nil
      @ip          = Sketchup::InputPoint.new
      @snap_scales = []   # per-click scale ratios collected at each point
    end

    def activate
      Sketchup.set_status_text('Click first point of dimension')
    end

    def deactivate(view)
      view.invalidate
    end

    def onMouseMove(_flags, x, y, view)
      @ip.pick(view, x, y)
      @mouse = @ip.position
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      @ip.pick(view, x, y)
      pt = Geom::Point3d.new(@ip.position.x, @ip.position.y, 0)
      @pts << pt

      @snap_scales << pick_entity_scale(view, x, y) if @pts.length <= 2

      case @pts.length
      when 1
        Sketchup.set_status_text('Click second point')
      when 2
        Sketchup.set_status_text('Click to set dimension line offset')
      when 3
        place_dimension(*@pts)
        @pts         = []
        @snap_scales = []
        Sketchup.set_status_text('Click first point of dimension')
      end
      view.invalidate
    rescue => e
      @pts         = []
      @snap_scales = []
      puts "SketchDraw DimensionTool click error: #{e.message}"
      Sketchup.set_status_text('Click first point of dimension')
      view.invalidate
    end

    def onKeyDown(key, _repeat, _flags, _view)
      if key == 27
        @pts = []
        Sketchup.active_model.select_tool(nil)
      end
    end

    def draw(view)
      return if @pts.empty? || @mouse.nil?

      view.line_width    = 1
      view.line_stipple  = ''
      view.drawing_color = Sketchup::Color.new('red')

      if @pts.length >= 1
        view.draw_line(@pts[0], @mouse)
      end
      if @pts.length >= 2
        view.draw_line(@pts[0], @pts[1])
        raw   = @pts[0].distance(@pts[1])
        ratio = effective_scale
        real  = raw * ratio
        view.draw_text(@mouse, format_mm(real))
      end
    end

    private

    def place_dimension(pt1, pt2, offset_pt)
      model    = Sketchup.active_model
      entities = model.active_entities
      model.start_operation('Place Dimension', true)
      begin
        ratio      = effective_scale
        raw_dist   = pt1.distance(pt2)
        real_dist  = raw_dist * ratio
        label      = format_mm(real_dist)

        # Compute perpendicular offset so dimension line is always parallel to measured edge
        dir  = (pt2 - pt1).normalize
        perp = Geom::Vector3d.new(-dir.y, dir.x, 0).normalize
        raw  = offset_pt - Geom::Point3d.new((pt1.x + pt2.x) / 2.0,
                                              (pt1.y + pt2.y) / 2.0, 0)
        dist = raw.dot(perp)
        offset_vec = Geom::Vector3d.new(perp.x * dist, perp.y * dist, 0)

        dim = entities.add_dimension_linear(pt1, pt2, offset_vec)
        dim.text = label

        dim.set_attribute(ATTR_NS, 'type',     'dimension')
        dim.set_attribute(ATTR_NS, 'scale',    ratio)
        dim.set_attribute(ATTR_NS, 'raw_dist', raw_dist)

        model.commit_operation
      rescue => e
        model.abort_operation rescue nil
        puts "SketchDraw DimensionTool error: #{e.message}"
        puts e.backtrace.first(3).join("\n")
      end
    end

    # Returns the scale ratio to use for this dimension.
    # Priority: entity's applied_scale attribute (from pt1 click) → State.scale_ratio global
    def effective_scale
      # Use the scale stored on the first snapped entity when available
      if @snap_scales && !@snap_scales.empty?
        entity_scale = @snap_scales.first
        return entity_scale if entity_scale && entity_scale > 1
      end
      State.scale_ratio
    end

    # Walk up the pick path to find the nearest group with an applied_scale attribute.
    def pick_entity_scale(view, x, y)
      ph = view.pick_helper
      ph.do_pick(x, y)
      ph.count.times do |i|
        path = ph.path_at(i)
        next unless path
        path.reverse_each do |ent|
          next unless ent.respond_to?(:get_attribute)
          val = ent.get_attribute(ATTR_NS, 'applied_scale')
          return val.to_i if val && val.to_i > 1
        end
      end
      nil
    end

    def format_mm(mm)
      if mm >= 1000
        format('%.2fm', mm / 1000.0)
      else
        format('%.0fmm', mm)
      end
    end
  end
end
