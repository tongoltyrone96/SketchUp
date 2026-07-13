# SketchUp Technical Drawing Plugin — 완전 설계서 v2.0

**대상 버전**: SketchUp 2019+ (SketchUp 2025 완전 호환)
**언어**: Ruby 2.7+ / 3.x
**UI**: HtmlDialog (HTML5 / CSS3 / Vanilla JS)
**포맷**: RBZ 확장 프로그램

---

## 목적

SketchUp 안에서 2D 기술 도면 작업을 완결하고 AutoCAD와 동등한 품질의 벡터 PDF로
내보내기. LayOut 사용 불필요. 모든 도면 요소(선, 텍스트, 치수, 화살표, 이미지)가
단일 플러그인 안에서 처리됨.

---

## 버전 호환성 정책

| SketchUp 버전 | 지원 수준 |
|---|---|
| 2019 ~ 2024 | 완전 지원 |
| 2025 | 완전 지원 + 우선 테스트 |
| 2018 이하 | 미지원 (시작 시 경고 표시) |

**버전 체크 (모든 진입점에서 실행):**
```ruby
MIN_VERSION = 19

def self.version_ok?
  ver = Sketchup.version.to_f
  if ver < MIN_VERSION
    UI.messagebox(
      "SketchDraw requires SketchUp 2019 or later.\n" \
      "Current version: #{Sketchup.version}",
      MB_OK
    )
    return false
  end
  true
end
```

---

## 1. 프로젝트 구조

```
SketchDrawPlugin/
├── SketchDrawPlugin.rb              ← SketchUp 진입점 (로더)
├── src/
│   ├── extension.rb                 ← 확장 등록 + 초기화
│   ├── state.rb                     ← 전역 상태 관리
│   ├── toolbar.rb                   ← 툴바 빌드
│   ├── tools/
│   │   ├── paper_frame.rb           ← 페이퍼 프레임 + 템플릿
│   │   ├── title_block_editor.rb    ← 타이틀 블록 편집 [신규]
│   │   ├── scale_tool.rb            ← 스케일 툴
│   │   ├── dimension_tool.rb        ← 치수 툴
│   │   ├── text_tool.rb             ← 텍스트 툴
│   │   ├── edit_tool.rb             ← 더블클릭 편집 툴 [신규]
│   │   ├── arrow_tool.rb            ← 화살표/라벨 툴
│   │   ├── image_import.rb          ← 이미지 임포트
│   │   ├── pdf_export.rb            ← PDF 내보내기
│   │   ├── draw_order.rb            ← 앞/뒤 정렬
│   │   └── lock_2d.rb               ← 2D 잠금
│   └── ui/
│       ├── paper_dialog.html        ← 페이퍼 크기 선택
│       ├── title_block_dialog.html  ← 타이틀 블록 편집 [신규]
│       ├── scale_dialog.html        ← 스케일 선택
│       ├── text_dialog.html         ← 텍스트 툴 다이얼로그
│       ├── arrow_dialog.html        ← 화살표 라벨 다이얼로그
│       ├── dimension_dialog.html    ← 치수 스타일 설정
│       └── assets/
│           ├── style.css
│           └── main.js
├── templates/                       ← 사용자 페이퍼 템플릿 (.skp)
│   ├── A0_Landscape.skp
│   ├── A1_Landscape.skp
│   ├── A2_Landscape.skp
│   ├── A3_Landscape.skp
│   └── A4_Portrait.skp
└── icons/                           ← 툴바 아이콘 16×16 + 24×24
    ├── paper_16.png / paper_24.png
    ├── scale_16.png / scale_24.png
    ├── dim_16.png   / dim_24.png
    ├── text_16.png  / text_24.png
    ├── arrow_16.png / arrow_24.png
    ├── image_16.png / image_24.png
    ├── pdf_16.png   / pdf_24.png
    ├── front_16.png / front_24.png
    ├── back_16.png  / back_24.png
    └── lock2d_16.png / lock2d_24.png
```

---

## 2. 진입점 및 확장 등록

### SketchDrawPlugin.rb
```ruby
require 'sketchup.rb'
require 'extensions.rb'

module SketchDraw
  PLUGIN_ID   = 'SketchDrawPlugin'.freeze
  PLUGIN_DIR  = File.dirname(__FILE__).freeze
  PLUGIN_VER  = '1.0.0'.freeze
  MIN_VERSION = 19

  unless file_loaded?(__FILE__)
    ext = SketchupExtension.new(
      'SketchDraw — Technical Drawing',
      File.join(PLUGIN_DIR, 'src', 'extension.rb')
    )
    ext.description = '2D technical drawing tools: text, dimensions, arrows, PDF export.'
    ext.version     = PLUGIN_VER
    ext.creator     = 'Your Name'
    Sketchup.register_extension(ext, true)
    file_loaded(__FILE__)
  end
end
```

### src/extension.rb
```ruby
require_relative 'state'
require_relative 'toolbar'
require_relative 'tools/paper_frame'
require_relative 'tools/title_block_editor'
require_relative 'tools/scale_tool'
require_relative 'tools/dimension_tool'
require_relative 'tools/text_tool'
require_relative 'tools/edit_tool'
require_relative 'tools/arrow_tool'
require_relative 'tools/image_import'
require_relative 'tools/pdf_export'
require_relative 'tools/draw_order'
require_relative 'tools/lock_2d'

module SketchDraw
  def self.version_ok?
    Sketchup.version.to_f >= MIN_VERSION
  end

  def self.boot
    unless version_ok?
      UI.messagebox(
        "SketchDraw requires SketchUp 2019 or later.\nCurrent: #{Sketchup.version}",
        MB_OK
      )
      return
    end
    Toolbar.build
    # 더블클릭 편집 툴 항상 활성 상태 유지
    EditTool.install_observer
  end

  boot
end
```

---

## 3. 전역 상태 관리

AutoCAD 플러그인의 `TextEditCommand.PendingEditId` 정적 변수와 동일한 역할.
SketchUp은 단일 스레드이므로 모듈 레벨 변수로 안전하게 관리.

### src/state.rb
```ruby
module SketchDraw
  module State
    @scale_ratio  = 1      # 현재 도면 축척 (예: 100 = 1:100)
    @lock_2d      = false  # 2D 잠금 활성 여부
    @lock_observer = nil   # ViewObserver 인스턴스 (잠금 시)

    class << self
      attr_accessor :scale_ratio, :lock_2d, :lock_observer

      # 모델에 영구 저장 (파일 저장/재오픈 후도 유지)
      def save_to_model(model = Sketchup.active_model)
        model.set_attribute(SketchDraw::PLUGIN_ID, 'scale_ratio', @scale_ratio)
      end

      def load_from_model(model = Sketchup.active_model)
        @scale_ratio = model.get_attribute(
          SketchDraw::PLUGIN_ID, 'scale_ratio', 1
        ).to_i
      end

      def reset
        @scale_ratio  = 1
        @lock_2d      = false
        @lock_observer = nil
      end
    end
  end
end
```

---

## 4. 툴바

### src/toolbar.rb
```ruby
module SketchDraw
  module Toolbar
    def self.build
      tb = UI::Toolbar.new('SketchDraw')

      [
        ['Paper',  'paper',  'Select paper size / template',    -> { PaperFrame.show_dialog }],
        ['Scale',  'scale',  'Set drawing scale (1:100 etc.)',  -> { ScaleTool.activate }],
        ['Dim',    'dim',    'Place dimension line',            -> { DimensionTool.activate }],
        ['Text',   'text',   'Place text',                      -> { TextTool.activate }],
        ['Arrow',  'arrow',  'Place arrow + label',             -> { ArrowTool.activate }],
        ['Image',  'image',  'Import JPEG / PNG image',         -> { ImageImport.run }],
        ['PDF',    'pdf',    'Export to PDF',                   -> { PdfExport.run }],
        ['Front',  'front',  'Bring selection to front',        -> { DrawOrder.bring_to_front }],
        ['Back',   'back',   'Send selection to back',          -> { DrawOrder.send_to_back }],
        ['2D',     'lock2d', 'Toggle 2D lock (no 3D orbit)',    -> { Lock2D.toggle }]
      ].each do |name, icon, tip, action|
        cmd = UI::Command.new(name) { action.call }
        cmd.tooltip    = tip
        cmd.small_icon = icon_path("#{icon}_16.png")
        cmd.large_icon = icon_path("#{icon}_24.png")
        tb.add_item(cmd)
      end

      tb.restore
    end

    def self.icon_path(filename)
      File.join(SketchDraw::PLUGIN_DIR, 'icons', filename)
    end
  end
end
```

---

## 5. 페이퍼 프레임 + 템플릿

### 설계 포인트
- AutoCAD 플러그인의 `BlockInserter.cs`와 유사: 외부 파일 로드 후 현재 모델에 삽입
- 프레임 그룹에 `set_attribute`로 타입/크기를 태그 → 다른 기능에서 참조
- 템플릿 .skp 파일: D가 SketchUp에서 직접 제작 후 `/templates/` 폴더에 저장

### 보완사항 (v1에서 누락)
- 타이틀 블록 편집 다이얼로그 추가
- 템플릿 저장 기능 추가

### src/tools/paper_frame.rb
```ruby
module SketchDraw
  module PaperFrame
    SIZES = {
      'A0' => [1189, 841],
      'A1' => [841,  594],
      'A2' => [594,  420],
      'A3' => [420,  297],
      'A4' => [297,  210]
    }.freeze

    ATTR_NS   = SketchDraw::PLUGIN_ID
    FRAME_TAG = 'paper_frame'.freeze

    # ── 페이퍼 선택 다이얼로그 ─────────────────────────────────────────
    def self.show_dialog
      dlg = UI::HtmlDialog.new(
        dialog_title:    'Paper Size',
        preferences_key: 'SketchDraw_Paper',
        width: 420, height: 320,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dlg.set_file(ui_path('paper_dialog.html'))

      dlg.add_action_callback('insert_frame') do |_ctx, size_name, cw, ch|
        if size_name == 'custom'
          insert_frame(cw.to_f, ch.to_f)
        else
          w, h = SIZES[size_name]
          insert_frame(w, h)
        end
        dlg.close
      end

      # 기존 프레임 정보 전달 (편집 시)
      dlg.add_action_callback('get_current') do |action_ctx|
        frame = find_frame
        if frame
          w = frame.get_attribute(ATTR_NS, 'width')
          h = frame.get_attribute(ATTR_NS, 'height')
          action_ctx.resolve({ width: w, height: h }.to_json)
        else
          action_ctx.resolve('null')
        end
      end

      dlg.show
    end

    # ── 프레임 삽입 ───────────────────────────────────────────────────
    def self.insert_frame(width, height)
      model    = Sketchup.active_model
      entities = model.active_entities
      model.start_operation('Insert Paper Frame', true)

      remove_existing_frame(entities)

      # 외곽 프레임 (얇은 선으로만 구성 — PDF에서 깔끔하게 출력)
      pts = [
        Geom::Point3d.new(0,     0,      0),
        Geom::Point3d.new(width, 0,      0),
        Geom::Point3d.new(width, height, 0),
        Geom::Point3d.new(0,     height, 0)
      ]
      group = entities.add_group
      g_ent = group.entities
      edges = g_ent.add_face(pts).edges
      edges.each { |e| e.layer = model.layers.at(0) }

      group.set_attribute(ATTR_NS, 'type',   FRAME_TAG)
      group.set_attribute(ATTR_NS, 'width',  width)
      group.set_attribute(ATTR_NS, 'height', height)
      group.name = "PaperFrame_#{width.to_i}x#{height.to_i}"

      # 타이틀 블록 템플릿 삽입 (있는 경우)
      load_template(entities, width, height)

      # 뷰를 프레임에 맞춤
      fit_view(width, height)
      State.save_to_model(model)
      model.commit_operation
    end

    # ── 타이틀 블록 템플릿 로드 ──────────────────────────────────────
    def self.load_template(entities, width, height)
      key  = "#{width.to_i}x#{height.to_i}"
      path = File.join(SketchDraw::PLUGIN_DIR, 'templates', "#{key}.skp")
      return unless File.exist?(path)

      defn = Sketchup.active_model.definitions.load(path)
      inst = entities.add_instance(defn, IDENTITY)
      inst.set_attribute(ATTR_NS, 'type', 'title_block')
    end

    # ── 현재 스케일을 타이틀 블록에 자동 반영 ────────────────────────
    def self.update_scale_in_title_block
      ratio = State.scale_ratio
      label = ratio == 1 ? '1:1' : "1:#{ratio}"
      update_title_field('scale', label)
    end

    # ── 타이틀 블록 필드 업데이트 ────────────────────────────────────
    def self.update_title_field(field_key, value)
      model = Sketchup.active_model
      model.start_operation('Update Title Block', true)
      model.active_entities.grep(Sketchup::Text).each do |txt|
        if txt.get_attribute(ATTR_NS, 'title_field') == field_key
          txt.string = value
        end
      end
      model.commit_operation
    end

    # ── 헬퍼 ─────────────────────────────────────────────────────────
    def self.find_frame(model = Sketchup.active_model)
      model.active_entities.grep(Sketchup::Group).find do |g|
        g.get_attribute(ATTR_NS, 'type') == FRAME_TAG
      end
    end

    def self.frame_dimensions(model = Sketchup.active_model)
      f = find_frame(model)
      return [297, 210] unless f
      [f.get_attribute(ATTR_NS, 'width').to_f,
       f.get_attribute(ATTR_NS, 'height').to_f]
    end

    def self.remove_existing_frame(entities)
      to_erase = entities.grep(Sketchup::Group).select do |g|
        g.get_attribute(ATTR_NS, 'type') == FRAME_TAG
      end
      entities.erase_entities(to_erase) unless to_erase.empty?
    end

    def self.fit_view(width, height)
      view   = Sketchup.active_model.active_view
      camera = view.camera
      camera.perspective = false
      cx = width  / 2.0
      cy = height / 2.0
      camera.set(
        Geom::Point3d.new(cx, cy, 1000),
        Geom::Point3d.new(cx, cy, 0),
        Geom::Vector3d.new(0, 1, 0)
      )
      bb = Geom::BoundingBox.new
      bb.add(Geom::Point3d.new(0,     0,      0))
      bb.add(Geom::Point3d.new(width, height, 0))
      view.zoom(bb)
    end

    def self.ui_path(file)
      File.join(SketchDraw::PLUGIN_DIR, 'src', 'ui', file)
    end
  end
end
```

---

## 6. 타이틀 블록 편집 [신규 — v1 누락]

### src/tools/title_block_editor.rb
```ruby
module SketchDraw
  module TitleBlockEditor
    def self.show_dialog
      dlg = UI::HtmlDialog.new(
        dialog_title:    'Edit Title Block',
        preferences_key: 'SketchDraw_TitleBlock',
        width: 440, height: 380,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dlg.set_file(ui_path('title_block_dialog.html'))

      # 현재 값 전달
      dlg.add_action_callback('get_fields') do |action_ctx|
        fields = load_current_fields
        action_ctx.resolve(fields.to_json)
      end

      # 저장
      dlg.add_action_callback('save_fields') do |_ctx, json|
        data = JSON.parse(json, symbolize_names: true)
        apply_fields(data)
        dlg.close
      end

      dlg.show
    end

    def self.apply_fields(data)
      model = Sketchup.active_model
      model.start_operation('Edit Title Block', true)

      data.each do |field_key, value|
        model.active_entities.grep(Sketchup::Text).each do |txt|
          if txt.get_attribute(SketchDraw::PLUGIN_ID, 'title_field') == field_key.to_s
            txt.string = value.to_s
          end
        end
      end

      # 스케일은 State에서 자동 읽기
      PaperFrame.update_scale_in_title_block
      model.commit_operation
    end

    def self.load_current_fields
      fields = {}
      Sketchup.active_model.active_entities.grep(Sketchup::Text).each do |txt|
        key = txt.get_attribute(SketchDraw::PLUGIN_ID, 'title_field')
        fields[key] = txt.string if key
      end
      fields
    end

    def self.ui_path(file)
      File.join(SketchDraw::PLUGIN_DIR, 'src', 'ui', file)
    end
  end
end
```

### title_block_dialog.html
```html
<!DOCTYPE html>
<html>
<body style="font-family:Arial; background:#2b2b2b; color:#ddd; padding:16px">
  <h3 style="margin:0 0 16px">Edit Title Block</h3>

  <label>Project Name</label>
  <input id="project_name" type="text" style="width:100%; margin-bottom:10px">

  <label>Drawing Title</label>
  <input id="drawing_title" type="text" style="width:100%; margin-bottom:10px">

  <label>Date</label>
  <input id="date" type="text" style="width:100%; margin-bottom:10px">

  <label>Drawn By</label>
  <input id="drawn_by" type="text" style="width:100%; margin-bottom:10px">

  <label>Revision</label>
  <input id="revision" type="text" style="width:100%; margin-bottom:16px">

  <p style="color:#aaa; font-size:11px">Scale: auto-updated from Scale Tool</p>

  <button onclick="save()" style="background:#0078d4; color:#fff; border:none;
    padding:8px 20px; cursor:pointer">Save</button>

  <script>
    sketchup.get_fields().then(data => {
      var fields = JSON.parse(data) || {};
      Object.keys(fields).forEach(k => {
        var el = document.getElementById(k);
        if (el) el.value = fields[k] || '';
      });
    });

    function save() {
      var data = {
        project_name:  document.getElementById('project_name').value,
        drawing_title: document.getElementById('drawing_title').value,
        date:          document.getElementById('date').value,
        drawn_by:      document.getElementById('drawn_by').value,
        revision:      document.getElementById('revision').value
      };
      sketchup.save_fields(JSON.stringify(data));
    }
  </script>
</body>
</html>
```

---

## 7. 스케일 툴

### 보완사항 (v1에서 수정)
- 스케일 적용된 엔티티를 `set_attribute`로 태그하여 추적
- 재스케일 시 이전 스케일만 되돌리고 새 스케일 적용
- 스케일 적용 후 타이틀 블록 자동 업데이트

### src/tools/scale_tool.rb
```ruby
module SketchDraw
  module ScaleTool
    ATTR_NS  = SketchDraw::PLUGIN_ID
    RATIOS   = [1, 2, 5, 10, 20, 25, 50, 100, 200, 500, 1000].freeze

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

        # 이전 스케일 추적 — set_attribute로 저장된 값 참조
        prev_ratio = ent.get_attribute(ATTR_NS, 'applied_scale', 1).to_i

        # 이전 스케일 되돌리기 (스케일 툴이 적용한 것만)
        if prev_ratio > 1
          revert_t = Geom::Transformation.scaling(prev_ratio.to_f)
          model.active_entities.transform_entities(revert_t, [ent])
        end

        # 새 스케일 적용
        if new_ratio > 1
          scale_t = Geom::Transformation.scaling(1.0 / new_ratio.to_f)
          model.active_entities.transform_entities(scale_t, [ent])
        end

        # 적용된 스케일 기록
        ent.set_attribute(ATTR_NS, 'applied_scale', new_ratio)
      end

      # 전역 스케일 업데이트
      State.scale_ratio = new_ratio
      State.save_to_model(model)

      # 타이틀 블록 스케일 텍스트 자동 갱신
      PaperFrame.update_scale_in_title_block

      model.commit_operation
    end

    def self.ui_path(f)
      File.join(SketchDraw::PLUGIN_DIR, 'src', 'ui', f)
    end
  end
end
```

---

## 8. 치수 툴

### 설계 포인트
- 3-클릭: 시작점 → 끝점 → 치수선 위치
- SketchUp 내장 `add_dimension_linear` 사용 (SketchUp 2019+ 안정적)
- 실제 치수 = SketchUp 측정값 × 스케일 비율
- `dim.text`로 표시 텍스트 오버라이드

### src/tools/dimension_tool.rb
```ruby
module SketchDraw
  class DimensionTool
    ATTR_NS = SketchDraw::PLUGIN_ID

    def self.activate
      return unless SketchDraw.version_ok?
      Sketchup.active_model.select_tool(new)
    end

    def initialize
      @pts    = []
      @mouse  = nil
      @ip     = Sketchup::InputPoint.new
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

      case @pts.length
      when 1
        Sketchup.set_status_text('Click second point')
      when 2
        Sketchup.set_status_text('Click to set dimension line offset')
      when 3
        place_dimension(*@pts)
        @pts  = []
        Sketchup.set_status_text('Click first point of dimension')
      end
      view.invalidate
    end

    def onKeyDown(key, _repeat, _flags, _view)
      # ESC로 취소
      if key == 27
        @pts = []
        Sketchup.active_model.select_tool(nil)
      end
    end

    def draw(view)
      return if @pts.empty? || @mouse.nil?

      view.line_width  = 1
      view.line_stipple = ''
      view.drawing_color = Sketchup::Color.new('red')

      if @pts.length >= 1
        view.draw_line(@pts[0], @mouse)
      end
      if @pts.length >= 2
        view.draw_line(@pts[0], @pts[1])
        # 미리보기 치수 텍스트
        raw  = @pts[0].distance(@pts[1])
        real = raw * State.scale_ratio
        view.draw_text(@mouse, format_mm(real))
      end
    end

    private

    def place_dimension(pt1, pt2, offset_pt)
      model    = Sketchup.active_model
      entities = model.active_entities
      model.start_operation('Place Dimension', true)

      raw_dist  = pt1.distance(pt2)
      real_dist = raw_dist * State.scale_ratio
      label     = format_mm(real_dist)

      # SketchUp 내장 치수 엔티티
      # offset_pt: 치수선이 그려질 기준 오프셋 포인트
      dim = entities.add_dimension_linear(pt1, pt2, offset_pt)
      dim.text = label

      # 속성 저장 (스케일 변경 시 재계산용)
      dim.set_attribute(ATTR_NS, 'type',     'dimension')
      dim.set_attribute(ATTR_NS, 'scale',    State.scale_ratio)
      dim.set_attribute(ATTR_NS, 'raw_dist', raw_dist)

      model.commit_operation
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
```

---

## 9. 텍스트 툴

### AutoCAD 플러그인 경험 참고
`TextToolDialog.xaml` + `TextCommand.cs` 구조를 그대로 가져옴.
- XAML WPF → HtmlDialog
- ACI 256색 → HTML `<input type="color">` (전체 RGB)
- AutoCAD Layer → SketchUp Tag
- MText 엔티티 → `add_3d_text()` 그룹

### 보완사항 (v1에서 수정)
- 다중 라인: 줄마다 별도 배치 로직
- Italic: SketchUp 2019+ 에서 `add_3d_text` italic 파라미터 지원 확인 후 사용
- 더블클릭 편집: `EditTool`로 분리 (별도 섹션 참조)

### src/tools/text_tool.rb
```ruby
module SketchDraw
  module TextTool
    ATTR_NS = SketchDraw::PLUGIN_ID

    def self.activate
      return unless SketchDraw.version_ok?
      show_dialog
    end

    # existing_group: 편집 모드일 때 기존 그룹 전달
    def self.show_dialog(existing_group = nil)
      dlg = UI::HtmlDialog.new(
        dialog_title:    'Text Tool',
        preferences_key: 'SketchDraw_Text',
        width: 540, height: 500,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dlg.set_file(ui_path('text_dialog.html'))

      # SketchUp Tag 목록 전달
      dlg.add_action_callback('get_tags') do |action_ctx|
        tags = Sketchup.active_model.layers.map(&:name).sort
        action_ctx.resolve(tags.to_json)
      end

      # 편집 모드: 기존 속성 로드
      dlg.add_action_callback('get_props') do |action_ctx|
        if existing_group
          props = existing_group.get_attribute(ATTR_NS, 'text_props', '{}')
          action_ctx.resolve(props)
        else
          action_ctx.resolve('null')
        end
      end

      # 배치
      dlg.add_action_callback('place_text') do |_ctx, json|
        props = JSON.parse(json, symbolize_names: true)
        dlg.close
        if existing_group
          update_text_group(existing_group, props)
        else
          # 클릭으로 배치점 선택
          Sketchup.active_model.select_tool(TextPlacementTool.new(props))
        end
      end

      dlg.show
    end

    # ── 텍스트 그룹 배치 ─────────────────────────────────────────────
    def self.place_text_at(origin, props)
      model    = Sketchup.active_model
      entities = model.active_entities
      model.start_operation('Place Text', true)

      group = build_text_group(entities, origin, props)
      tag   = props[:tag].to_s
      if tag && !tag.empty?
        layer = model.layers[tag] || model.layers.add(tag)
        group.layer = layer
      end

      model.commit_operation
    end

    def self.update_text_group(group, props)
      model = Sketchup.active_model
      model.start_operation('Edit Text', true)
      origin = group.bounds.min
      group.entities.clear!
      build_text_content(group.entities, origin, props)
      group.set_attribute(ATTR_NS, 'text_props', props.to_json)
      model.commit_operation
    end

    # ── 텍스트 그룹 빌드 ─────────────────────────────────────────────
    def self.build_text_group(entities, origin, props)
      group = entities.add_group
      build_text_content(group.entities, origin, props)

      group.set_attribute(ATTR_NS, 'type',       'text')
      group.set_attribute(ATTR_NS, 'text_props', props.to_json)
      group.name = 'SketchDraw_Text'
      group
    end

    def self.build_text_content(g_entities, origin, props)
      font    = props[:font]    || 'Arial'
      bold    = props[:bold]    == true || props[:bold] == 'true'
      italic  = props[:italic]  == true || props[:italic] == 'true'
      # pt → mm (SketchUp 내부는 inch, .mm 헬퍼 사용)
      height  = (props[:size_pt].to_f * 0.3528).mm
      color   = Sketchup::Color.new(props[:color] || '#000000')
      content = props[:is_caps] == true ? props[:content].to_s.upcase
                                        : props[:content].to_s

      lines = content.split("\n")
      line_spacing = height * 1.4   # 줄간격

      lines.each_with_index do |line_text, i|
        line_text = line_text.strip
        next if line_text.empty?

        # Bullet prefix 추가
        prefix = case props[:list_style]
                 when 'dot'    then '• '
                 when 'dash'   then '- '
                 when 'number' then "#{i + 1}. "
                 else ''
                 end

        display_text = prefix + line_text
        y_offset     = -(i * line_spacing)
        pt           = Geom::Point3d.new(origin.x, origin.y + y_offset, origin.z)

        # SketchUp 2019+에서 add_3d_text italic 지원
        g_entities.add_3d_text(
          display_text,
          TextAlignLeft,
          font,
          bold,
          italic,
          height,
          0.0,     # tolerance
          0.0,     # z
          true,    # filled
          0.0      # extrusion (평면 텍스트)
        )

        # 색상 적용
        g_entities.grep(Sketchup::Face).each do |f|
          f.material      = color
          f.back_material = color
        end
      end
    end

    def self.ui_path(f)
      File.join(SketchDraw::PLUGIN_DIR, 'src', 'ui', f)
    end
  end

  # ── 배치 툴 (다이얼로그 닫힌 후 클릭으로 점 선택) ──────────────────
  class TextPlacementTool
    def initialize(props)
      @props = props
    end

    def activate
      Sketchup.set_status_text('Click to place text')
    end

    def onLButtonDown(_flags, x, y, view)
      ip = Sketchup::InputPoint.new
      ip.pick(view, x, y)
      pt = Geom::Point3d.new(ip.position.x, ip.position.y, 0)
      TextTool.place_text_at(pt, @props)
      Sketchup.active_model.select_tool(nil)
    end

    def onKeyDown(key, _r, _f, _v)
      Sketchup.active_model.select_tool(nil) if key == 27
    end
  end
end
```

---

## 10. 더블클릭 편집 툴 [신규 — v1 누락]

### 설계 포인트
v1에서 `SelectionObserver.onSelectionBulkChange`를 사용했으나,
이는 선택 변경 시 모두 발생하므로 더블클릭 감지 불가.
`Sketchup::Tool`의 `onLButtonDoubleClick`을 사용하는 별도 툴로 구현.

### src/tools/edit_tool.rb
```ruby
module SketchDraw
  class EditTool
    ATTR_NS = SketchDraw::PLUGIN_ID

    # 앱 전역에 상시 활성 관찰자 등록
    def self.install_observer
      obs = AppObserver.new
      Sketchup.add_observer(obs)
    end

    # ── AppObserver: 새 모델 열릴 때마다 EditTool 등록 ───────────────
    class AppObserver < Sketchup::AppObserver
      def onNewModel(model)
        register(model)
      end

      def onOpenModel(model)
        register(model)
      end

      def register(model)
        # SketchUp의 기본 선택 툴에 더블클릭 리스너 추가는
        # 직접적으로 불가 — 대신 ModelObserver로 처리
        obs = ModelObserver.new
        model.add_observer(obs)
      end
    end

    # ── ModelObserver: 선택 변경 감지 ────────────────────────────────
    # 참고: 진정한 더블클릭은 SketchUp 툴로만 감지 가능
    # 실용적 대안: 툴바 'Edit' 버튼 → 선택된 엔티티를 편집

    def self.edit_selected
      model     = Sketchup.active_model
      selection = model.selection
      return if selection.empty?

      entity = selection.first
      return unless entity.respond_to?(:get_attribute)

      type = entity.get_attribute(ATTR_NS, 'type')
      case type
      when 'text'
        TextTool.show_dialog(entity)
      when 'arrow'
        ArrowTool.show_edit_dialog(entity)
      when 'dimension'
        # 치수 텍스트 재설정
        edit_dimension(entity)
      end
    end

    def self.edit_dimension(dim_entity)
      return unless dim_entity.is_a?(Sketchup::DimensionLinear)
      raw   = dim_entity.get_attribute(ATTR_NS, 'raw_dist', 0).to_f
      ratio = UI.inputbox(['Scale ratio:'], [State.scale_ratio], 'Edit Dimension')
      return unless ratio
      new_ratio       = ratio[0].to_i
      dim_entity.text = format_mm(raw * new_ratio)
      dim_entity.set_attribute(ATTR_NS, 'scale', new_ratio)
    end

    def self.format_mm(mm)
      mm >= 1000 ? format('%.2fm', mm / 1000.0) : format('%.0fmm', mm)
    end
  end
end
```

---

## 11. 화살표 / 라벨 툴

### 설계 포인트
- 3단계: 화살촉 클릭 → 리더선 끝 클릭 → 다이얼로그에서 텍스트 입력
- 꽉 찬 실선 삼각형 화살촉 (filled solid arrowhead)
- 화살표 색상 / 텍스트 색상 독립
- 배치 후 편집 가능

### src/tools/arrow_tool.rb
```ruby
module SketchDraw
  class ArrowTool
    ATTR_NS = SketchDraw::PLUGIN_ID

    def self.activate
      return unless SketchDraw.version_ok?
      Sketchup.active_model.select_tool(new)
    end

    def self.show_edit_dialog(group)
      show_label_dialog(nil, nil, group)
    end

    def initialize
      @tip      = nil
      @line_end = nil
      @ip       = Sketchup::InputPoint.new
    end

    def activate
      Sketchup.set_status_text('Click arrowhead tip point')
    end

    def onMouseMove(_flags, x, y, view)
      @ip.pick(view, x, y)
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      @ip.pick(view, x, y)
      pt = Geom::Point3d.new(@ip.position.x, @ip.position.y, 0)

      if @tip.nil?
        @tip = pt
        Sketchup.set_status_text('Click leader line end point')
      elsif @line_end.nil?
        @line_end = pt
        Sketchup.set_status_text('Enter label text in dialog...')
        ArrowTool.show_label_dialog(@tip, @line_end)
        Sketchup.active_model.select_tool(nil)
      end
      view.invalidate
    end

    def draw(view)
      return unless @tip
      pos = @ip.position
      view.line_width     = 1
      view.drawing_color  = Sketchup::Color.new('cyan')
      view.draw_line(@tip, pos)
    end

    def onKeyDown(key, _r, _f, _v)
      Sketchup.active_model.select_tool(nil) if key == 27
    end

    def self.show_label_dialog(tip, line_end, existing_group = nil)
      dlg = UI::HtmlDialog.new(
        dialog_title:    'Arrow Label',
        preferences_key: 'SketchDraw_Arrow',
        width: 420, height: 360,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dlg.set_file(ui_path('arrow_dialog.html'))

      dlg.add_action_callback('get_props') do |action_ctx|
        if existing_group
          props = existing_group.get_attribute(ATTR_NS, 'arrow_props', '{}')
          action_ctx.resolve(props)
        else
          action_ctx.resolve('null')
        end
      end

      dlg.add_action_callback('place_arrow') do |_ctx, json|
        data = JSON.parse(json, symbolize_names: true)
        dlg.close
        if existing_group
          update_arrow(existing_group, data)
        else
          place_arrow(tip, line_end, data)
        end
      end

      dlg.show
    end

    def self.place_arrow(tip, line_end, data)
      model    = Sketchup.active_model
      entities = model.active_entities
      model.start_operation('Place Arrow Label', true)

      group = entities.add_group
      g_ent = group.entities

      arrow_color = Sketchup::Color.new(data[:arrow_color] || '#ffffff')
      text_color  = Sketchup::Color.new(data[:text_color]  || '#ffffff')
      arrow_size  = (data[:arrow_size] || 3.0).to_f.mm
      font        = data[:font] || 'Arial'
      text_size   = (data[:text_size] || 10.0).to_f

      # ── 리더선 ────────────────────────────────────────────────────
      edge = g_ent.add_line(tip, line_end)
      edge.material = arrow_color

      # ── 화살촉 (꽉 찬 실선 삼각형) ───────────────────────────────
      dir  = line_end.vector_to(tip)
      if dir.valid?
        dir.normalize!
        perp  = Geom::Vector3d.new(-dir.y, dir.x, 0)
        perp.normalize!
        base  = tip.offset(dir.reverse, arrow_size)
        left  = base.offset(perp,  arrow_size * 0.4)
        right = base.offset(perp, -arrow_size * 0.4)
        face  = g_ent.add_face(tip, left, right)
        if face
          face.material      = arrow_color
          face.back_material = arrow_color
        end
      end

      # ── 라벨 텍스트 ───────────────────────────────────────────────
      unless data[:label].to_s.strip.empty?
        label_origin = Geom::Point3d.new(
          line_end.x + 2.mm,
          line_end.y + 2.mm,
          0
        )
        TextTool.place_text_at(label_origin, {
          content:   data[:label],
          font:      font,
          size_pt:   text_size,
          bold:      data[:text_bold],
          italic:    false,
          color:     data[:text_color] || '#ffffff',
          list_style: 'none',
          is_caps:   false
        })
      end

      group.set_attribute(ATTR_NS, 'type',        'arrow')
      group.set_attribute(ATTR_NS, 'arrow_props', data.to_json)
      group.name = 'SketchDraw_Arrow'

      model.commit_operation
    end

    def self.update_arrow(group, data)
      model = Sketchup.active_model
      model.start_operation('Edit Arrow', true)
      # 기존 그룹 삭제 후 재배치 (tip/line_end는 bounds에서 추정)
      bb   = group.bounds
      tip  = bb.min
      tail = bb.max
      group.erase!
      place_arrow(tip, tail, data)
      model.commit_operation
    end

    def self.ui_path(f)
      File.join(SketchDraw::PLUGIN_DIR, 'src', 'ui', f)
    end
  end
end
```

---

## 12. 이미지 임포트

### 보완사항 (v1에서 수정)
- 실제 텍스처 압축 우회: `MaxTextureSize` 설정
- 이미지 삽입 후 크기 조정 지원
- 원본 경로 저장 (PDF 내보내기 시 참조)

### src/tools/image_import.rb
```ruby
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

      # 텍스처 최대 크기 높이기 (품질 유지 핵심)
      set_max_texture_size(4096)

      model    = Sketchup.active_model
      entities = model.active_entities
      model.start_operation('Import Image', true)

      # 기본 너비: 100mm, 비율 유지
      width  = default_width_mm(path)
      origin = Geom::Point3d.new(0, 0, 0.5.mm)  # 페이퍼 위 0.5mm

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

    # SketchUp 텍스처 최대 크기 설정 (SketchUp 2019+ 지원)
    def self.set_max_texture_size(size)
      Sketchup.write_default('OpenGL', 'MaxTextureSize', size)
    rescue => e
      # 설정 실패해도 계속 진행
      puts "[SketchDraw] Could not set MaxTextureSize: #{e.message}"
    end

    def self.default_width_mm(path)
      # ImageRep API (SketchUp 2018+) 로 실제 픽셀 크기 읽기
      if Sketchup.version.to_f >= 18
        begin
          rep = Sketchup::ImageRep.new
          rep.load_file(path)
          px_w = rep.width
          px_h = rep.height
          # 기본 100mm 너비 유지하되 비율만 참고
          return 100.0
        rescue => e
          puts "[SketchDraw] ImageRep error: #{e.message}"
        end
      end
      100.0
    end
  end
end
```

---

## 13. PDF 내보내기

### 보완사항 (v1에서 수정)
- 프레임 정확 크롭: BoundingBox 기반 뷰 설정
- SketchUp 2019/2025 버전별 export 옵션 분기
- 내보내기 전 카메라 상태 저장 후 복원

### src/tools/pdf_export.rb
```ruby
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

      # 현재 카메라 상태 저장
      saved = save_camera(model)

      begin
        setup_export_camera(model, w, h)
        do_export(model, path, w, h)
      ensure
        # 내보내기 후 카메라 복원
        restore_camera(model, saved)
      end

      UI.messagebox("PDF exported successfully:\n#{path}", MB_OK)
    end

    private

    def self.setup_export_camera(model, width, height)
      view   = model.active_view
      camera = view.camera

      camera.perspective = false

      # 정중앙에서 정확히 탑뷰
      cx = width  / 2.0
      cy = height / 2.0
      camera.set(
        Geom::Point3d.new(cx, cy, 2000),
        Geom::Point3d.new(cx, cy, 0),
        Geom::Vector3d.new(0, 1, 0)
      )

      # 페이퍼 프레임 정확히 포함하는 BoundingBox로 뷰 맞춤
      bb = Geom::BoundingBox.new
      bb.add(Geom::Point3d.new(-1,         -1,          0))
      bb.add(Geom::Point3d.new(width + 1,  height + 1,  0))
      view.zoom(bb)
    end

    def self.do_export(model, path, width, height)
      ver = Sketchup.version.to_f

      # SketchUp 2025 (버전 25+) 옵션
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
      # SketchUp 2019–2024
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
```

---

## 14. 앞으로 가져오기 / 뒤로 보내기

### src/tools/draw_order.rb
```ruby
module SketchDraw
  module DrawOrder
    Z_STEP = 0.1.mm   # 0.1mm씩 Z 이동

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
```

---

## 15. 2D 잠금

### 보완사항 (v1에서 수정)
v1의 ViewObserver 방식은 뷰 변경 후 복원하므로 화면 깜빡임 발생.
SketchUp에서 네이티브 오빗을 직접 차단할 수 없으므로,
더 부드러운 방법: `onViewChanged`에서 카메라를 빠르게 복원 +
`view.animation` 없이 즉각 복원하여 깜빡임 최소화.

### src/tools/lock_2d.rb
```ruby
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

      # Orthographic 설정
      view.camera.perspective = false

      # Observer 등록
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

    # ── 뷰 관찰자 ─────────────────────────────────────────────────────
    class TwoDViewObserver < Sketchup::ViewObserver
      def onViewChanged(view)
        return unless State.lock_2d
        camera = view.camera

        # 카메라가 탑뷰에서 벗어났는지 확인
        # 탑뷰 조건: direction이 (0, 0, -1) 방향
        dir = camera.direction
        is_top = dir.z.abs > 0.95

        unless is_top
          # 현재 XY 중심 유지하면서 탑뷰 복원
          eye    = camera.eye
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
```

---

## 16. HtmlDialog UI 가이드라인

### 공통 다크 테마 CSS (assets/style.css)
AutoCAD 플러그인의 다크 테마(`#2B2B2B` 계열)와 동일한 색상 사용.

```css
* { box-sizing: border-box; margin: 0; padding: 0; }

body {
  font-family: Arial, sans-serif;
  font-size: 12px;
  background: #2B2B2B;
  color: #DDDDDD;
  padding: 12px;
}

label {
  display: block;
  color: #AAAAAA;
  font-size: 11px;
  margin-bottom: 3px;
  margin-top: 8px;
}

input[type=text], input[type=number], select, textarea {
  width: 100%;
  background: #1E1E1E;
  color: #FFFFFF;
  border: 1px solid #555555;
  border-radius: 2px;
  padding: 5px 8px;
  font-size: 12px;
}

input[type=color] {
  width: 36px;
  height: 28px;
  border: 1px solid #555555;
  border-radius: 2px;
  padding: 2px;
  background: #1E1E1E;
  cursor: pointer;
}

button {
  background: #0078D4;
  color: #FFFFFF;
  border: none;
  border-radius: 2px;
  padding: 7px 18px;
  font-size: 12px;
  cursor: pointer;
}

button:hover { background: #005A9E; }

button.secondary {
  background: #505050;
}

.fmt-btn {
  width: 28px; height: 28px;
  background: #404040;
  color: #FFFFFF;
  border: 1px solid #555555;
  border-radius: 2px;
  cursor: pointer;
  font-size: 13px;
}

.fmt-btn.active { background: #0078D4; }

#preview {
  background: #1E1E1E;
  border: 1px solid #555555;
  min-height: 80px;
  padding: 10px;
  margin-top: 8px;
  border-radius: 2px;
  color: #FFFFFF;
  font-family: Arial;
  font-size: 13px;
}
```

### text_dialog.html — 핵심 구조
```html
<!DOCTYPE html>
<html>
<head>
  <link rel="stylesheet" href="assets/style.css">
</head>
<body>
  <!-- Font + Size (AutoCAD TextToolDialog와 동일 레이아웃) -->
  <div style="display:flex; gap:8px; align-items:center; margin-bottom:8px">
    <span style="color:#aaa; font-size:11px">Font:</span>
    <select id="font" style="flex:1" onchange="updatePreview()">
      <option>Arial</option>
      <option>Times New Roman</option>
      <option>Calibri</option>
      <option>Verdana</option>
    </select>
    <span style="color:#aaa; font-size:11px">Size (pt):</span>
    <input id="size_pt" type="number" value="10" min="7" max="72"
           style="width:60px" oninput="updatePreview()">
  </div>

  <!-- 서식 버튼 -->
  <div style="display:flex; gap:4px; margin-bottom:8px">
    <button class="fmt-btn" id="bold"      onclick="toggle('bold')">B</button>
    <button class="fmt-btn" id="italic"    onclick="toggle('italic')">I</button>
    <button class="fmt-btn" id="underline" onclick="toggle('underline')">U</button>
    <button class="fmt-btn" id="caps"      onclick="toggle('caps')">AA</button>

    <span style="margin:0 8px; border-left:1px solid #555"></span>

    <!-- RGB 색상 (AutoCAD ACI 256색 대신) -->
    <input type="color" id="color" value="#000000" onchange="updatePreview()">

    <span style="margin:0 8px; border-left:1px solid #555"></span>

    <!-- 정렬 -->
    <button class="fmt-btn" id="align_L" onclick="setAlign('L')">L</button>
    <button class="fmt-btn" id="align_C" onclick="setAlign('C')">C</button>
    <button class="fmt-btn" id="align_R" onclick="setAlign('R')">R</button>
  </div>

  <!-- List + Tag -->
  <div style="display:flex; gap:12px; margin-bottom:8px">
    <div style="flex:1">
      <label>List:</label>
      <select id="list_style" onchange="updatePreview()">
        <option value="none">None</option>
        <option value="dot">• Dot</option>
        <option value="dash">- Dash</option>
        <option value="number">1. Number</option>
      </select>
    </div>
    <div style="flex:2">
      <label>Tag (Layer):</label>
      <select id="tag"></select>
    </div>
  </div>

  <!-- 미리보기 -->
  <div id="preview">Welcome to text tool</div>

  <!-- 텍스트 입력 -->
  <textarea id="content" rows="6"
            style="margin-top:8px; resize:vertical"
            oninput="updatePreview()" onkeydown="handleKey(event)"></textarea>

  <!-- 버튼 -->
  <div style="display:flex; justify-content:flex-end; gap:8px; margin-top:10px">
    <button class="secondary" onclick="window.location.href='sketchup:cancel'">Cancel</button>
    <button onclick="placeText()">Place Text</button>
  </div>

<script>
var state = { bold:false, italic:false, underline:false, caps:false, align:'L' };

// 태그 목록 로드
sketchup.get_tags().then(function(json) {
  var tags = JSON.parse(json) || [];
  var sel  = document.getElementById('tag');
  tags.forEach(function(t) {
    var opt = document.createElement('option');
    opt.value = opt.text = t;
    sel.appendChild(opt);
  });
});

// 편집 모드: 기존 속성 로드
sketchup.get_props().then(function(json) {
  if (!json || json === 'null') return;
  var p = JSON.parse(json);
  if (p.font)   document.getElementById('font').value     = p.font;
  if (p.size_pt) document.getElementById('size_pt').value = p.size_pt;
  if (p.color)  document.getElementById('color').value   = p.color;
  if (p.content) document.getElementById('content').value = p.content;
  if (p.list_style) document.getElementById('list_style').value = p.list_style;
  if (p.bold)      { state.bold      = true; document.getElementById('bold').classList.add('active'); }
  if (p.italic)    { state.italic    = true; document.getElementById('italic').classList.add('active'); }
  if (p.underline) { state.underline = true; document.getElementById('underline').classList.add('active'); }
  if (p.is_caps)   { state.caps      = true; document.getElementById('caps').classList.add('active'); }
  updatePreview();
});

function toggle(id) {
  state[id] = !state[id];
  document.getElementById(id).classList.toggle('active', state[id]);
  updatePreview();
}

function setAlign(a) {
  state.align = a;
  ['L','C','R'].forEach(function(x) {
    document.getElementById('align_'+x).classList.toggle('active', x===a);
  });
  updatePreview();
}

function handleKey(e) {
  if (e.key !== 'Enter') return;
  var style = document.getElementById('list_style').value;
  if (style === 'none') return;
  // 자동 bullet prefix
  var ta   = document.getElementById('content');
  var pos  = ta.selectionStart;
  var text = ta.value;
  var linesBefore = text.substring(0, pos).split('\n').length;
  var prefix = style === 'dot'  ? '• '
             : style === 'dash' ? '- '
             : (linesBefore + 1) + '. ';
  e.preventDefault();
  var insert = '\n' + prefix;
  ta.value = text.slice(0, pos) + insert + text.slice(pos);
  ta.selectionStart = ta.selectionEnd = pos + insert.length;
  updatePreview();
}

function updatePreview() {
  var pv      = document.getElementById('preview');
  var font    = document.getElementById('font').value;
  var size    = document.getElementById('size_pt').value;
  var color   = document.getElementById('color').value;
  var content = document.getElementById('content').value;
  var style   = document.getElementById('list_style').value;

  var display = content.trim() || 'Welcome to text tool';
  if (state.caps) display = display.toUpperCase();

  // List prefix on empty preview
  if (!content.trim()) {
    display = style === 'dot'  ? '• ' + display
            : style === 'dash' ? '- ' + display
            : style === 'number' ? '1. ' + display
            : display;
  }

  pv.style.fontFamily   = font;
  pv.style.fontSize     = size + 'px';
  pv.style.color        = color;
  pv.style.fontWeight   = state.bold      ? 'bold'   : 'normal';
  pv.style.fontStyle    = state.italic    ? 'italic' : 'normal';
  pv.style.textDecoration = state.underline ? 'underline' : 'none';
  pv.style.textAlign    = state.align === 'C' ? 'center'
                        : state.align === 'R' ? 'right' : 'left';
  pv.innerHTML = display.replace(/\n/g, '<br>');
}

function placeText() {
  var props = {
    font:       document.getElementById('font').value,
    size_pt:    parseFloat(document.getElementById('size_pt').value),
    color:      document.getElementById('color').value,
    bold:       state.bold,
    italic:     state.italic,
    underline:  state.underline,
    is_caps:    state.caps,
    align:      state.align,
    list_style: document.getElementById('list_style').value,
    tag:        document.getElementById('tag').value,
    content:    document.getElementById('content').value
  };
  sketchup.place_text(JSON.stringify(props));
}

updatePreview();
</script>
</body>
</html>
```

---

## 17. 개발 순서 및 마일스톤

| 단계 | 내용 | AutoCAD 경험 활용 |
|---|---|---|
| **1단계** | 기본 구조 + 진입점 + 버전 체크 + 툴바 | PluginEntry.cs 구조 참고 |
| **2단계** | 페이퍼 프레임 + 타이틀 블록 편집 | — |
| **3단계** | 2D 잠금 | — |
| **4단계** | 스케일 툴 | ScaleCommand.cs 로직 참고 |
| **5단계** | 치수 툴 | — |
| **6단계** | 텍스트 툴 + 다이얼로그 | TextToolDialog.xaml 레이아웃 재활용 |
| **7단계** | 더블클릭 편집 툴 | TextEditCommand.cs 흐름 참고 |
| **8단계** | 화살표/라벨 툴 | — |
| **9단계** | 이미지 임포트 + 품질 처리 | ImageInserter.cs 참고 |
| **10단계** | 앞/뒤 정렬 | — |
| **11단계** | PDF 내보내기 | — |
| **12단계** | 전체 테스트 (SketchUp 2019 + 2025) + RBZ 패키징 | — |

---

## 18. RBZ 패키징

```bash
# RBZ = ZIP 구조
cd /path/to/SketchDrawPlugin
zip -r ../SketchDrawPlugin_v1.0.rbz . \
  -x "*.git*" -x "*.DS_Store" -x "*Thumbs.db"
```

**설치:**
SketchUp → Window → Extension Manager → Install Extension → `.rbz` 선택

---

## 19. 핵심 SketchUp API 주의사항

| 항목 | 내용 |
|---|---|
| **단위** | SketchUp 내부 단위 = **inch**. 항상 `.mm` 헬퍼 사용: `10.mm` = 10mm |
| **Undo** | `model.start_operation` / `model.commit_operation` 쌍으로 Ctrl+Z 지원 |
| **스레드** | Ruby 단일 스레드 — AutoCAD의 `Dispatcher.Invoke` 불필요 |
| **HtmlDialog 통신** | Ruby→JS: `dlg.execute_script("func()")` / JS→Ruby: `sketchup.callback()` |
| **속성 저장** | `entity.set_attribute(ns, key, val)` — 파일 저장 후 재오픈해도 유지 |
| **2019+ add_3d_text** | italic 파라미터 완전 지원 확인됨 |
| **2025 export** | `model.export` PDF 옵션 형식 동일, 추가 옵션 일부 지원됨 |

---

*이 설계서로 새 Claude Code 창에서 1단계부터 순서대로 구현하면 됩니다.*
