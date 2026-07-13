module SketchDraw
  module ScaleTool
    ATTR_NS = SketchDraw::PLUGIN_ID
    RATIOS  = [1, 2, 5, 10, 20, 25, 50, 100, 200, 500, 1000].freeze

    def self.activate
      return unless SketchDraw.version_ok?
      model = Sketchup.active_model
      if model.selection.empty?
        UI.messagebox('Select objects to scale first, then run Scale tool.')
        return
      end
      show_dialog(model.selection.to_a)
    end

    def self.show_dialog(entities)
      dlg = UI::HtmlDialog.new(
        dialog_title:    'Set Drawing Scale',
        preferences_key: 'SketchDraw_Scale',
        width: 380, height: 280,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dlg.set_file(ui_path('scale_dialog.html'))

      dlg.add_action_callback('get_current_scale') do |action_ctx|
        action_ctx.resolve(State.scale_ratio.to_s)
      end

      dlg.add_action_callback('apply_scale') do |_ctx, ratio_str|
        ratio = ratio_str.to_i
        apply(entities, ratio)
        dlg.close
      end

      dlg.show
    end

    def self.apply(entities, new_ratio)
      model = Sketchup.active_model
      model.start_operation("Set Scale 1:#{new_ratio}", true)

      entities.each do |ent|
        next unless ent.respond_to?(:get_attribute)

        prev_ratio = ent.get_attribute(ATTR_NS, 'applied_scale', 1).to_i

        if prev_ratio > 1
          revert_t = Geom::Transformation.scaling(prev_ratio.to_f)
          model.active_entities.transform_entities(revert_t, [ent])
        end

        if new_ratio > 1
          scale_t = Geom::Transformation.scaling(1.0 / new_ratio.to_f)
          model.active_entities.transform_entities(scale_t, [ent])
        end

        ent.set_attribute(ATTR_NS, 'applied_scale', new_ratio)
      end

      State.scale_ratio = new_ratio
      State.save_to_model(model)

      PaperFrame.update_scale_in_title_block

      model.commit_operation
    end

    def self.ui_path(f)
      File.join(SketchDraw::PLUGIN_DIR, 'src', 'ui', f)
    end
  end
end
