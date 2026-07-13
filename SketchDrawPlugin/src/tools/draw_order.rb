module SketchDraw
  module DrawOrder
    Z_STEP = 0.1.mm

    def self.bring_to_front
      move_z(Z_STEP, 'Bring to Front')
    end

    def self.send_to_back
      move_z(-Z_STEP, 'Send to Back')
    end

    private

    def self.move_z(delta, op_name)
      model     = Sketchup.active_model
      selection = model.selection

      if selection.empty?
        UI.messagebox('Select one or more objects first.')
        return
      end

      model.start_operation(op_name, true)
      t = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, delta))
      model.active_entities.transform_entities(t, selection.to_a)
      model.commit_operation
    end
  end
end
