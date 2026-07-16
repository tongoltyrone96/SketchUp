module SketchDraw
  module ScaleTool
    ATTR_NS = SketchDraw::PLUGIN_ID
    RATIOS  = [1, 2, 5, 10, 20, 25, 50, 100, 200, 500, 1000].freeze

    def self.activate
      return unless SketchDraw.version_ok?
      model   = Sketchup.active_model
      sel     = model.selection

      if sel.empty?
        UI.messagebox('Select objects to scale first, then run Scale tool.')
        return
      end

      entities = sel.to_a
      single   = entities.length == 1 && (
        entities[0].is_a?(Sketchup::Group) ||
        entities[0].is_a?(Sketchup::ComponentInstance)
      )

      unless single
        model.start_operation('Auto-group for Scale', true)
        grp = model.active_entities.add_group(entities)
        model.commit_operation
        sel.clear
        sel.add(grp)
        entities = [grp]
      end

      show_dialog(entities)
    end

    def self.show_dialog(entities)
      dlg = UI::HtmlDialog.new(
        dialog_title:    'Set Drawing Scale',
        preferences_key: 'SketchDraw_Scale_v2',
        width: 380, height: 300,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dlg.set_file(ui_path('scale_dialog.html'))

      dlg.add_action_callback('get_current_scale') do |_ctx|
        entity_scale = nil
        entities.each do |ent|
          next unless ent.respond_to?(:get_attribute)
          val = ent.get_attribute(ATTR_NS, 'applied_scale')
          next unless val && val.to_i > 0
          entity_scale = val.to_i
          break
        end
        result = (entity_scale || 1).to_i
        dlg.execute_script("receiveScale(#{result})")
      end

      dlg.add_action_callback('apply_scale') do |_ctx, ratio_str|
        begin
          ratio = ratio_str.to_i
          apply(entities, ratio)
        rescue => e
          puts "SketchDraw ScaleTool error: #{e.message}"
          puts e.backtrace.first(5).join("\n")
        ensure
          dlg.close
          UI.start_timer(0.05, false) do
            Sketchup.active_model.select_tool(nil)
            Sketchup.active_model.active_view.invalidate
          end
        end
      end

      dlg.add_action_callback('cancel') { dlg.close }

      dlg.show
    end

    def self.apply(entities, new_ratio)
      model = Sketchup.active_model
      model.start_operation("Set Scale 1:#{new_ratio}", true)

      entities.each do |ent|
        next unless ent.respond_to?(:get_attribute)

        prev_ratio = ent.get_attribute(ATTR_NS, 'applied_scale', 1).to_i
        center     = ent.bounds.center

        if prev_ratio > 1
          model.active_entities.transform_entities(
            Geom::Transformation.scaling(center, prev_ratio.to_f), [ent]
          )
        end

        if new_ratio > 1
          model.active_entities.transform_entities(
            Geom::Transformation.scaling(center, 1.0 / new_ratio.to_f), [ent]
          )
        end

        ent.set_attribute(ATTR_NS, 'applied_scale', new_ratio)
      end

      State.scale_ratio = new_ratio
      State.save_to_model(model)
      model.commit_operation

      UI.start_timer(0, false) { correct_native_dims(Sketchup.active_model) }

      if new_ratio > 1
        State.install_native_dim_observer(model)
      else
        State.remove_native_dim_observer(model)
      end

      begin
        PaperFrame.update_scale_in_title_block
      rescue => e
        puts "SketchDraw: title block scale update failed: #{e.message}"
      end
    end

    def self.fmt_mm(mm)
      mm >= 1000 ? format('%.2fm', mm / 1000.0) : format('%.0fmm', mm)
    end

    # Resolves a dimension endpoint to Geom::Point3d regardless of SketchUp version.
    # SU2014+ documented: dim.start returns [Entity_or_nil, Geom::Point3d]
    # Some versions:      dim.start returns Geom::Point3d directly
    # Older versions:     dim.start returns DimensionLinear::StartPoint with .position
    def self.dim_point(endpoint)
      return nil if endpoint.nil?
      if endpoint.is_a?(Array)
        pt = endpoint[1]
        return pt.is_a?(Geom::Point3d) ? pt : nil
      end
      return endpoint if endpoint.is_a?(Geom::Point3d)
      return endpoint.position if endpoint.respond_to?(:position)
      nil
    end

    # Returns the applied_scale of the smallest scaled entity whose WORLD bounds
    # contain pt1 or pt2 (with epsilon). Used by NativeDimObserver for newly-placed
    # dims whose endpoints are already in current world space.
    def self.scale_for_points(model, pt1, pt2)
      best_ratio  = 0
      best_volume = Float::INFINITY
      eps = 0.01  # ~0.25 mm

      model.active_entities.each do |ent|
        next unless ent.respond_to?(:get_attribute) && ent.respond_to?(:bounds)
        ratio = ent.get_attribute(ATTR_NS, 'applied_scale').to_i
        next unless ratio > 1
        bb = ent.bounds
        next unless bb.valid?
        mn = bb.min; mx = bb.max
        in_bb = ->(pt) {
          pt.x >= mn.x - eps && pt.x <= mx.x + eps &&
          pt.y >= mn.y - eps && pt.y <= mx.y + eps &&
          pt.z >= mn.z - eps && pt.z <= mx.z + eps
        }
        next unless in_bb.call(pt1) || in_bb.call(pt2)
        vol = bb.width * bb.height * bb.depth
        best_volume, best_ratio = vol, ratio if vol < best_volume
      end
      best_ratio
    end

    # Returns the real-world distance (mm) for a dimension whose endpoints may be in
    # EITHER current world space OR the group's local (pre-scale) space.
    #
    # dim.start in SketchUp can return two kinds of coords depending on version and
    # whether the vertex was moved into a group:
    #   Case A – world coords: pt dist = physical (scaled) size → real = dist * ratio
    #   Case B – local/frozen coords: pt dist = original (pre-scale) = real-world size → real = dist
    #
    # Strategy: try world bounds first (Case A). If that fails, try the group's own
    # LOCAL bounding box (Case B). Both produce the same real-world answer.
    def self.real_world_for_dim(model, pt1, pt2)
      physical_mm = pt1.distance(pt2).to_mm
      return nil if physical_mm < 0.001

      best_real   = nil
      best_volume = Float::INFINITY
      eps = 0.01

      model.active_entities.each do |ent|
        next unless ent.respond_to?(:get_attribute) && ent.respond_to?(:bounds)
        ratio = ent.get_attribute(ATTR_NS, 'applied_scale').to_i
        next unless ratio > 1

        # ── Case A: world-space bounds ───────────────────────────────────────
        world_bb = ent.bounds
        if world_bb.valid?
          mn = world_bb.min; mx = world_bb.max
          in_world = ->(pt) {
            pt.x >= mn.x - eps && pt.x <= mx.x + eps &&
            pt.y >= mn.y - eps && pt.y <= mx.y + eps &&
            pt.z >= mn.z - eps && pt.z <= mx.z + eps
          }
          if in_world.call(pt1) || in_world.call(pt2)
            rw  = physical_mm * ratio
            vol = world_bb.width * world_bb.height * world_bb.depth
            best_volume, best_real = vol, rw if vol < best_volume
            next
          end
        end

        # ── Case B: group local-space bounds (dim.start returns pre-scale coords)
        next unless ent.is_a?(Sketchup::Group)
        local_bb = Geom::BoundingBox.new
        ent.entities.each { |e| local_bb.add(e.bounds) if e.respond_to?(:bounds) }
        next unless local_bb.valid?
        lmn = local_bb.min; lmx = local_bb.max
        in_local = ->(pt) {
          pt.x >= lmn.x - eps && pt.x <= lmx.x + eps &&
          pt.y >= lmn.y - eps && pt.y <= lmx.y + eps &&
          pt.z >= lmn.z - eps && pt.z <= lmx.z + eps
        }
        next unless in_local.call(pt1) || in_local.call(pt2)
        # Local/frozen coords: physical_mm already equals the real-world distance
        vol = local_bb.width * local_bb.height * local_bb.depth
        best_volume, best_real = vol, physical_mm if vol < best_volume
      end

      best_real
    end

    # Re-labels all native (non-plugin) dimension entities.
    # Searches both top-level entities AND inside scaled groups (dims can end up
    # inside a group when the user selects geometry+dims together before scaling).
    def self.correct_native_dims(model)
      all_fixes = []

      # 1. Top-level native dims
      model.active_entities.grep(Sketchup::DimensionLinear).each do |d|
        next if d.get_attribute(ATTR_NS, 'type') == 'dimension'
        all_fixes << { dim: d, inside_group: false }
      end

      # 2. Native dims inside scaled groups
      model.active_entities.each do |ent|
        next unless ent.is_a?(Sketchup::Group)
        next unless ent.get_attribute(ATTR_NS, 'applied_scale').to_i > 1
        ent.entities.grep(Sketchup::DimensionLinear).each do |d|
          next if d.get_attribute(ATTR_NS, 'type') == 'dimension'
          all_fixes << { dim: d, inside_group: true }
        end
      end

      return if all_fixes.empty?

      model.start_operation('Fix Dimension Labels', true)
      begin
        all_fixes.each do |item|
          dim = item[:dim]
          pt1 = dim_point(dim.start)
          pt2 = dim_point(dim.end)
          next unless pt1 && pt2

          if item[:inside_group]
            # Endpoints are in the group's LOCAL space (unchanged by scale transform).
            # Local distance = original = real-world size — no ratio multiplication needed.
            local_mm = pt1.distance(pt2).to_mm
            next if local_mm < 0.001
            dim.text = fmt_mm(local_mm)
          else
            rw = real_world_for_dim(model, pt1, pt2)
            dim.text = rw ? fmt_mm(rw) : ''
          end
        end
        model.commit_operation
      rescue => e
        model.abort_operation rescue nil
        puts "SketchDraw correct_native_dims: #{e.message}"
        puts e.backtrace.first(3).join("\n")
      end
    end

    def self.ui_path(f)
      File.join(SketchDraw::PLUGIN_DIR, 'src', 'ui', f)
    end
  end

  # Watches for native SketchUp dimension entities added while scale > 1
  # and overwrites their text with the real-world value automatically.
  class NativeDimObserver < Sketchup::EntitiesObserver
    ATTR_NS = SketchDraw::PLUGIN_ID

    def onElementAdded(_entities, entity)
      return unless entity.is_a?(Sketchup::DimensionLinear)
      return if entity.get_attribute(ATTR_NS, 'type') == 'dimension'

      UI.start_timer(0, false) do
        next unless entity.valid?
        model = Sketchup.active_model
        pt1   = ScaleTool.dim_point(entity.start)
        pt2   = ScaleTool.dim_point(entity.end)
        next unless pt1 && pt2

        # New dims use current world coords → scale_for_points (world bounds) is enough
        ratio = ScaleTool.scale_for_points(model, pt1, pt2)
        next unless ratio > 1

        physical_mm = pt1.distance(pt2).to_mm
        next if physical_mm < 0.001

        model.start_operation('Fix Dimension Label', true)
        begin
          entity.text = ScaleTool.fmt_mm(physical_mm * ratio)
          model.commit_operation
        rescue
          model.abort_operation rescue nil
        end
      end
    end
  end
end
