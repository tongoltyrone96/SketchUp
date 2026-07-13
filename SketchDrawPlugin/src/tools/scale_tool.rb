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

      begin
        PaperFrame.update_scale_in_title_block
      rescue => e
        puts "SketchDraw: title block scale update failed: #{e.message}"
      end
    end

    def self.ui_path(f)
      File.join(SketchDraw::PLUGIN_DIR, 'src', 'ui', f)
    end
  end
end
