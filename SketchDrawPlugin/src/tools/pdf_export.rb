module SketchDraw
  module PdfExport
    ATTR_NS      = SketchDraw::PLUGIN_ID
    PDF_FONT_MAP = {
      'Arial'           => 'Helvetica',
      'Times New Roman' => 'Times-Roman',
      'Courier New'     => 'Courier',
      'Helvetica'       => 'Helvetica',
      'Times'           => 'Times-Roman',
      'Courier'         => 'Courier'
    }.freeze

    def self.log(msg)
      puts "[SketchDraw PDF] #{msg}"
    end
    private_class_method :log

    # ── Entry point ──────────────────────────────────────────────────────
    def self.run
      model = Sketchup.active_model
      return unless SketchDraw.version_ok?

      frame = PaperFrame.find_frame(model)
      unless frame
        UI.messagebox('No paper frame found. Please insert a paper frame first (Paper button).', MB_OK)
        return
      end

      pdf_path = UI.savepanel('Export PDF', '', 'PDF Files|*.pdf||')
      return unless pdf_path
      pdf_path += '.pdf' unless pdf_path.end_with?('.pdf')

      paper_w_mm = frame.get_attribute(ATTR_NS, 'width').to_f
      paper_h_mm = frame.get_attribute(ATTR_NS, 'height').to_f

      log "--- START --- path=#{pdf_path}"
      log "Paper attr: width=#{paper_w_mm}mm height=#{paper_h_mm}mm"

      prog = UI::HtmlDialog.new(
        dialog_title: 'SketchDraw — PDF Export',
        width: 400, height: 130,
        left: 560, top: 420,
        resizable: false, scrollable: false,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      prog.set_html(<<~HTML)
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          * { margin:0; padding:0; box-sizing:border-box; }
          body { background:#1e1e1e; color:#fff; font-family:Arial,sans-serif;
                 display:flex; align-items:center; justify-content:center;
                 height:100vh; text-align:center; }
          .msg { font-size:15px; font-weight:bold; }
          .sub { font-size:12px; opacity:0.6; margin-top:8px; }
        </style></head>
        <body>
          <div>
            <div class="msg">Exporting PDF...</div>
            <div class="sub">Please wait — building vector PDF</div>
          </div>
        </body></html>
      HTML
      prog.show

      UI.start_timer(0.3, false) do
        perform_export(model, frame, pdf_path, paper_w_mm, paper_h_mm, prog)
      end
    end

    # ── Core export ──────────────────────────────────────────────────────
    def self.perform_export(model, frame, pdf_path, paper_w_mm, paper_h_mm, prog)
      fb   = frame.bounds
      @fx0 = fb.min.x
      @fy0 = fb.min.y
      @wpt = (paper_w_mm * 72.0 / 25.4).round(4)
      @hpt = (paper_h_mm * 72.0 / 25.4).round(4)
      @images     = {}
      @img_idx    = 0
      @used_fonts = {}

      log "Frame bounds min=(#{@fx0.round(4)}, #{@fy0.round(4)})"
      log "PDF page: #{@wpt}pt x #{@hpt}pt"

      if @wpt < 1 || @hpt < 1
        log "ERROR: invalid page size (#{@wpt} x #{@hpt}) — paper attributes missing?"
        UI.messagebox("PDF export error: page size is 0.\nPlease re-insert the paper frame.", MB_OK)
        prog.close rescue nil
        return
      end

      Sketchup.set_status_text('SketchDraw: building vector PDF...')

      face_buf = String.new('', encoding: 'BINARY')
      edge_buf = String.new('', encoding: 'BINARY')

      log "Traversing entities (count=#{model.active_entities.count})..."
      traverse(model.active_entities, Geom::Transformation.new, face_buf, edge_buf)

      log "face_buf: #{face_buf.bytesize} bytes"
      log "edge_buf: #{edge_buf.bytesize} bytes"
      log "images registered: #{@images.length} — #{@images.keys.inspect}"
      log "fonts registered:  #{@used_fonts.inspect}"

      clip    = "0 0 #{fn(@wpt)} #{fn(@hpt)} re W n\n"
      content = String.new('', encoding: 'BINARY')
      content << "q\n"
      content << clip.encode('BINARY')
      content << face_buf
      content << edge_buf
      content << "Q\n"

      log "content stream: #{content.bytesize} bytes  encoding=#{content.encoding}"

      pdf_bytes = build_pdf(content)
      log "PDF binary: #{pdf_bytes.bytesize} bytes  encoding=#{pdf_bytes.encoding}"

      File.binwrite(pdf_path, pdf_bytes)
      actual_size = File.size(pdf_path)
      log "File written: #{actual_size} bytes at #{pdf_path}"

      Sketchup.set_status_text('')
      prog.close rescue nil
      UI.messagebox("PDF saved (#{actual_size} bytes):\n#{pdf_path}", MB_OK)
    rescue => e
      Sketchup.set_status_text('')
      prog.close rescue nil
      log "EXCEPTION: #{e.class}: #{e.message}"
      e.backtrace.first(8).each { |l| log "  #{l}" }
      UI.messagebox("PDF export error:\n#{e.class}: #{e.message}", MB_OK)
    end
    private_class_method :perform_export

    # ── Entity traversal ─────────────────────────────────────────────────
    def self.traverse(entities, xform, fbuf, ebuf)
      entities.each do |ent|
        next if ent_hidden?(ent)
        case ent
        when Sketchup::Group
          emit_group(ent, xform, fbuf, ebuf)
        when Sketchup::ComponentInstance
          log "  ComponentInstance: #{ent.definition.name}"
          traverse(ent.definition.entities, xform * ent.transformation, fbuf, ebuf)
        when Sketchup::Face
          emit_face(ent, xform, fbuf)
        when Sketchup::Edge
          emit_edge(ent, xform, ebuf)
        when Sketchup::Text
          emit_su_text(ent, xform, ebuf)
        when Sketchup::DimensionLinear
          emit_dimension(ent, xform, ebuf)
        end
      end
    end
    private_class_method :traverse

    def self.ent_hidden?(ent)
      return true if ent.respond_to?(:hidden?) && ent.hidden?
      return true if ent.respond_to?(:layer) && ent.layer && !ent.layer.visible?
      false
    end
    private_class_method :ent_hidden?

    def self.emit_group(grp, xform, fbuf, ebuf)
      type        = grp.get_attribute(ATTR_NS, 'type')
      child_xform = xform * grp.transformation
      log "  Group name=#{grp.name.inspect} type=#{type.inspect} entities=#{grp.entities.count}"
      case type
      when 'image' then emit_image_group(grp, fbuf)
      when 'text'  then emit_text_group(grp, child_xform, ebuf)
      else              traverse(grp.entities, child_xform, fbuf, ebuf)
      end
    end
    private_class_method :emit_group

    # ── Image group ───────────────────────────────────────────────────────
    def self.emit_image_group(grp, fbuf)
      path = grp.get_attribute(ATTR_NS, 'orig_path')
      log "  [image] orig_path=#{path.inspect}"

      unless path
        log "  [image] SKIP: no orig_path attribute"
        return
      end
      unless File.exist?(path)
        log "  [image] SKIP: file not found at #{path}"
        return
      end

      b  = grp.bounds
      pw = b.width  * 72.0
      ph = b.height * 72.0
      log "  [image] bounds: width=#{b.width.round(4)}in height=#{b.height.round(4)}in => #{pw.round(1)}x#{ph.round(1)}pt"

      if pw < 0.01 || ph < 0.01
        log "  [image] SKIP: zero size"
        return
      end

      file_size = File.size(path)
      ext       = File.extname(path).downcase
      log "  [image] reading file: #{file_size} bytes  ext=#{ext}"

      raw = File.binread(path) rescue (log "  [image] ERROR reading file"; return)

      log "  [image] calling image_payload..."
      w, h, filt, payload = image_payload(raw, ext)
      log "  [image] image_payload result: w=#{w} h=#{h} filter=#{filt.inspect} payload=#{payload&.bytesize}bytes"

      unless w && w > 0 && payload
        log "  [image] SKIP: image_payload failed"
        return
      end

      px, py = su_to_pdf(b.min.x, b.min.y)
      name   = "Im#{@img_idx}"
      @img_idx += 1
      @images[name] = { w: w, h: h, filter: filt, data: payload }
      log "  [image] registered as #{name}  pdf_pos=(#{px.round(1)},#{py.round(1)})  pdf_size=#{pw.round(1)}x#{ph.round(1)}"
      fbuf << "q #{fn(pw)} 0 0 #{fn(ph)} #{fn(px)} #{fn(py)} cm /#{name} Do Q\n"
    end
    private_class_method :emit_image_group

    # ── Text group (type='text', has text_props) ──────────────────────────
    def self.emit_text_group(grp, xform, ebuf)
      json = grp.get_attribute(ATTR_NS, 'text_props')
      return unless json
      props = JSON.parse(json) rescue (log "  [text] JSON parse failed"; return)
      content = props['content'].to_s
      return if content.empty?
      content = content.upcase if props['is_caps']
      fp = map_font(props['font'])
      sz = [props['size_pt'].to_f, 1.0].max
      r, g, b = hex_rgb(props['color'] || '#000000')
      register_font(fp)
      fk = @used_fonts[fp]

      log "  [text] content=#{content[0, 40].inspect} font=#{fp} size=#{sz}"

      line_grps = grp.entities.grep(Sketchup::Group).sort_by do |lg|
        -(xform * lg.transformation).origin.y
      end

      if line_grps.empty?
        log "  [text] SKIP: no line sub-groups found"
        return
      end

      non_empty = content.split("\n").map(&:strip).reject(&:empty?)
      non_empty.each_with_index do |line, i|
        lg = line_grps[i] || line_grps.last
        t  = (xform * lg.transformation).origin
        ox, oy = su_to_pdf(t.x, t.y)
        log "  [text] line#{i}: #{line[0,30].inspect} pos=(#{ox.round(1)},#{oy.round(1)})"
        ebuf << "BT /#{fk} #{fn(sz)} Tf #{fn(r)} #{fn(g)} #{fn(b)} rg " \
                "#{fn(ox)} #{fn(oy)} Td (#{pdf_escape(line)}) Tj ET\n"
      end
    end
    private_class_method :emit_text_group

    # ── Sketchup::Text (title block field values, leader text) ────────────
    def self.emit_su_text(txt, xform, ebuf)
      str = begin
        txt.respond_to?(:string) ? txt.string.to_s : txt.text.to_s
      rescue
        ''
      end
      str = str.strip
      return if str.empty?
      pt = txt.respond_to?(:point) ? txt.point : nil
      return unless pt
      wp = pt.transform(xform)
      px, py = su_to_pdf(wp.x, wp.y)
      register_font('Helvetica')
      fk = @used_fonts['Helvetica']
      log "  [su_text] #{str[0,30].inspect} pos=(#{px.round(1)},#{py.round(1)})"
      ebuf << "BT /#{fk} 7 Tf 0 0 0 rg #{fn(px)} #{fn(py)} Td (#{pdf_escape(str)}) Tj ET\n"
    end
    private_class_method :emit_su_text

    # ── Face (filled polygon) ─────────────────────────────────────────────
    def self.emit_face(face, xform, fbuf)
      mat = face.material || face.back_material
      r, g, b = mat_rgb(mat, 0.93)
      fbuf << "#{fn(r)} #{fn(g)} #{fn(b)} rg\n"
      face.loops.each do |loop|
        pts = loop.vertices.map { |v| v.position.transform(xform) }
        next if pts.length < 3
        px0, py0 = su_to_pdf(pts[0].x, pts[0].y)
        fbuf << "#{fn(px0)} #{fn(py0)} m\n"
        pts[1..-1].each do |pt|
          px, py = su_to_pdf(pt.x, pt.y)
          fbuf << "#{fn(px)} #{fn(py)} l\n"
        end
        fbuf << "f\n"
      end
    end
    private_class_method :emit_face

    # ── Edge (line) ───────────────────────────────────────────────────────
    def self.emit_edge(edge, xform, ebuf)
      return if edge.hidden?
      r, g, b = mat_rgb(edge.material, 0.0)
      p1 = edge.start.position.transform(xform)
      p2 = edge.end.position.transform(xform)
      x1, y1 = su_to_pdf(p1.x, p1.y)
      x2, y2 = su_to_pdf(p2.x, p2.y)
      ebuf << "#{fn(r)} #{fn(g)} #{fn(b)} RG 0.5 w #{fn(x1)} #{fn(y1)} m #{fn(x2)} #{fn(y2)} l S\n"
    end
    private_class_method :emit_edge

    # ── Dimension linear ──────────────────────────────────────────────────
    def self.emit_dimension(dim, xform, ebuf)
      pt1 = dim.start.position.transform(xform)
      pt2 = dim.end.position.transform(xform)
      off = dim.offset
      d1  = Geom::Point3d.new(pt1.x + off.x, pt1.y + off.y, 0)
      d2  = Geom::Point3d.new(pt2.x + off.x, pt2.y + off.y, 0)
      x1,  y1  = su_to_pdf(pt1.x, pt1.y)
      xd1, yd1 = su_to_pdf(d1.x,  d1.y)
      x2,  y2  = su_to_pdf(pt2.x, pt2.y)
      xd2, yd2 = su_to_pdf(d2.x,  d2.y)
      ebuf << "0 0 0 RG 0.35 w #{fn(x1)} #{fn(y1)} m #{fn(xd1)} #{fn(yd1)} l S\n"
      ebuf << "0 0 0 RG 0.35 w #{fn(x2)} #{fn(y2)} m #{fn(xd2)} #{fn(yd2)} l S\n"
      ebuf << "0 0 0 RG 0.5 w #{fn(xd1)} #{fn(yd1)} m #{fn(xd2)} #{fn(yd2)} l S\n"
      label = dim.text.to_s.strip
      return if label.empty?
      mid_x = (xd1 + xd2) / 2.0
      mid_y = (yd1 + yd2) / 2.0 + 3.5
      register_font('Helvetica')
      fk = @used_fonts['Helvetica']
      ebuf << "BT /#{fk} 8 Tf 0 0 0 rg #{fn(mid_x)} #{fn(mid_y)} Td (#{pdf_escape(label)}) Tj ET\n"
    rescue => e
      log "  [dimension] ERROR: #{e.message}"
    end
    private_class_method :emit_dimension

    # ── Coordinate / format helpers ───────────────────────────────────────
    def self.su_to_pdf(x, y)
      [(x - @fx0) * 72.0, (y - @fy0) * 72.0]
    end
    private_class_method :su_to_pdf

    def self.fn(v)
      format('%.4f', v.to_f).sub(/\.?0+$/, '')
    end
    private_class_method :fn

    def self.map_font(name)
      PDF_FONT_MAP[name.to_s] || 'Helvetica'
    end
    private_class_method :map_font

    def self.register_font(pdf_font)
      @used_fonts[pdf_font] ||= "F#{@used_fonts.size + 1}"
    end
    private_class_method :register_font

    def self.hex_rgb(hex)
      parts = hex.to_s.gsub('#', '').scan(/../)
      return [0.0, 0.0, 0.0] if parts.length < 3
      parts.first(3).map { |s| s.to_i(16) / 255.0 }
    end
    private_class_method :hex_rgb

    def self.mat_rgb(mat, default)
      if mat && mat.respond_to?(:color) && mat.color
        c = mat.color
        [c.red / 255.0, c.green / 255.0, c.blue / 255.0]
      else
        [default, default, default]
      end
    end
    private_class_method :mat_rgb

    def self.pdf_escape(str)
      str.to_s
         .encode('ISO-8859-1', invalid: :replace, undef: :replace, replace: '?')
         .gsub('\\', '\\\\')
         .gsub('(', '\\(')
         .gsub(')', '\\)')
    end
    private_class_method :pdf_escape

    # ── PDF binary assembly ───────────────────────────────────────────────
    def self.build_pdf(content_str)
      require 'zlib'
      log "build_pdf: compressing #{content_str.bytesize}b content..."
      cs = Zlib::Deflate.deflate(content_str.force_encoding('BINARY'), Zlib::BEST_COMPRESSION)
      log "build_pdf: compressed to #{cs.bytesize}b"

      next_id  = 5
      font_ids = {}
      @used_fonts.each { |pf, _| font_ids[pf] = next_id; next_id += 1 }
      log "build_pdf: fonts=#{font_ids.inspect}"

      img_ids  = {}
      img_objs = {}
      @images.each do |name, info|
        next unless info[:data] && info[:w].to_i > 0
        img_ids[name]  = next_id
        img_objs[name] = info
        log "build_pdf: image #{name} id=#{next_id} #{info[:w]}x#{info[:h]} #{info[:filter]}"
        next_id += 1
      end

      total = next_id - 1
      log "build_pdf: total objects=#{total}"

      font_res = @used_fonts.map { |pf, fk| "/#{fk} #{font_ids[pf]} 0 R" }.join(' ')
      xobj_res = img_ids.map    { |n,  id| "/#{n} #{id} 0 R" }.join(' ')

      res = String.new('', encoding: 'BINARY')
      res << "/Font << #{font_res} >> "    unless font_res.empty?
      res << "/XObject << #{xobj_res} >>"  unless xobj_res.empty?
      log "build_pdf: Resources=#{res.inspect[0, 120]}"

      buf = String.new("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n", encoding: 'BINARY')
      off = {}

      off[1] = buf.bytesize
      buf << "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
      log "build_pdf: obj1 Catalog at offset #{off[1]}"

      off[2] = buf.bytesize
      buf << "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
      log "build_pdf: obj2 Pages at offset #{off[2]}"

      off[3] = buf.bytesize
      page_dict = "3 0 obj\n<< /Type /Page /Parent 2 0 R " \
                  "/MediaBox [0 0 #{fn(@wpt)} #{fn(@hpt)}] " \
                  "/Contents 4 0 R /Resources << #{res} >> >>\nendobj\n"
      buf << page_dict
      log "build_pdf: obj3 Page at offset #{off[3]}  MediaBox=[0 0 #{fn(@wpt)} #{fn(@hpt)}]"

      off[4] = buf.bytesize
      buf << "4 0 obj\n<< /Length #{cs.bytesize} /Filter /FlateDecode >>\nstream\n"
      buf << cs
      buf << "\nendstream\nendobj\n"
      log "build_pdf: obj4 Content at offset #{off[4]}  stream=#{cs.bytesize}b"

      @used_fonts.each do |pf, _fk|
        id = font_ids[pf]
        off[id] = buf.bytesize
        buf << "#{id} 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /#{pf} " \
               "/Encoding /WinAnsiEncoding >>\nendobj\n"
        log "build_pdf: obj#{id} Font /#{pf} at offset #{off[id]}"
      end

      img_objs.each do |name, d|
        id = img_ids[name]
        off[id] = buf.bytesize
        buf << "#{id} 0 obj\n" \
               "<< /Type /XObject /Subtype /Image /Width #{d[:w]} /Height #{d[:h]} " \
               "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /#{d[:filter]} " \
               "/Length #{d[:data].bytesize} >>\nstream\n"
        buf << d[:data]
        buf << "\nendstream\nendobj\n"
        log "build_pdf: obj#{id} Image #{name} #{d[:w]}x#{d[:h]} at offset #{off[id]}"
      end

      xp = buf.bytesize
      buf << "xref\n0 #{total + 1}\n0000000000 65535 f \n"
      (1..total).each { |n| buf << format('%010d 00000 n ', off[n] || 0) << "\n" }
      buf << "trailer\n<< /Size #{total + 1} /Root 1 0 R >>\nstartxref\n#{xp}\n%%EOF\n"
      log "build_pdf: xref at #{xp}  total buf=#{buf.bytesize}b"
      buf
    end
    private_class_method :build_pdf

    # ── Image helpers ─────────────────────────────────────────────────────
    def self.image_payload(raw, ext)
      log "  [image_payload] ext=#{ext} raw=#{raw.bytesize}b"
      if ['.jpg', '.jpeg'].include?(ext)
        w, h = jpeg_dims(raw)
        log "  [image_payload] JPEG dims: #{w}x#{h}"
        return [0, 0, nil, nil] if w == 0
        [w, h, 'DCTDecode', raw]
      else
        w, h = png_dims(raw)
        log "  [image_payload] PNG dims: #{w}x#{h}"
        return [0, 0, nil, nil] if w == 0
        log "  [image_payload] decoding PNG pixels..."
        rgb  = png_to_rgb(raw, w, h)
        log "  [image_payload] raw RGB: #{rgb.bytesize}b (expected #{w*h*3}b)"
        comp = Zlib::Deflate.deflate(rgb, Zlib::BEST_COMPRESSION)
        log "  [image_payload] compressed RGB: #{comp.bytesize}b"
        [w, h, 'FlateDecode', comp]
      end
    rescue => e
      log "  [image_payload] EXCEPTION: #{e.class}: #{e.message}"
      e.backtrace.first(4).each { |l| log "    #{l}" }
      [0, 0, nil, nil]
    end
    private_class_method :image_payload

    def self.jpeg_dims(data)
      i = 2
      while i < data.bytesize - 4
        return [0, 0] unless data.getbyte(i) == 0xFF
        marker = data.getbyte(i + 1)
        len    = data[i + 2, 2].unpack1('n')
        if [0xC0, 0xC1, 0xC2, 0xC9].include?(marker)
          return [data[i + 7, 2].unpack1('n'), data[i + 5, 2].unpack1('n')]
        end
        i += 2 + len
      end
      [0, 0]
    end
    private_class_method :jpeg_dims

    def self.png_dims(data)
      return [0, 0] if data.bytesize < 24
      [data[16, 4].unpack1('N'), data[20, 4].unpack1('N')]
    end
    private_class_method :png_dims

    def self.png_to_rgb(data, pw, ph)
      require 'zlib'
      pos      = 8
      idat     = String.new('', encoding: 'BINARY')
      channels = 3
      while pos < data.bytesize
        len  = data[pos, 4].unpack1('N')
        type = data[pos + 4, 4]
        if type == 'IHDR'
          ct       = data[pos + 8 + 9, 1].unpack1('C') rescue 2
          channels = case ct
                     when 0 then 1
                     when 2 then 3
                     when 3 then 1
                     when 4 then 2
                     when 6 then 4
                     else 3
                     end
          log "  [png_to_rgb] IHDR: #{pw}x#{ph} color_type=#{ct} channels=#{channels}"
        end
        idat << data[pos + 8, len] if type == 'IDAT'
        pos += 12 + len
      end
      log "  [png_to_rgb] IDAT total: #{idat.bytesize}b, inflating..."
      raw    = Zlib::Inflate.inflate(idat)
      log "  [png_to_rgb] inflated: #{raw.bytesize}b (expected #{ph*(pw*channels+1)}b)"
      stride = pw * channels
      out    = String.new('', encoding: 'BINARY')
      prev   = "\x00".b * stride
      ph.times do |y|
        base   = y * (stride + 1)
        filter = raw.getbyte(base)
        row    = raw[base + 1, stride].bytes
        case filter
        when 1
          stride.times { |i| row[i] = (row[i] + (i >= channels ? row[i - channels] : 0)) & 0xFF }
        when 2
          pb = prev.bytes
          stride.times { |i| row[i] = (row[i] + pb[i]) & 0xFF }
        when 3
          pb = prev.bytes
          stride.times { |i|
            a = i >= channels ? row[i - channels] : 0
            row[i] = (row[i] + ((a + pb[i]) >> 1)) & 0xFF
          }
        when 4
          pb = prev.bytes
          stride.times { |i|
            a  = i >= channels ? row[i - channels] : 0
            b  = pb[i]
            c  = i >= channels ? pb[i - channels] : 0
            p2 = a + b - c
            pa = (p2 - a).abs; pb2 = (p2 - b).abs; pc = (p2 - c).abs
            pr = pa <= pb2 && pa <= pc ? a : pb2 <= pc ? b : c
            row[i] = (row[i] + pr) & 0xFF
          }
        end
        prev = row.pack('C*')
        rgb  = String.new('', encoding: 'BINARY')
        case channels
        when 4
          pw.times { |i| rgb << prev[i * 4, 3] }
        when 2
          pw.times { |i| g = prev[i * 2, 1]; rgb << g << g << g }
        when 1
          pw.times { |i| g = prev[i, 1]; rgb << g << g << g }
        else
          rgb = prev
        end
        out << rgb
      end
      out
    end
    private_class_method :png_to_rgb
  end
end
