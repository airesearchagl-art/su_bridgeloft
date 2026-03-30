# =============================================================================
# su_bridgeloft - SketchUp Plugin: Loft between two ComponentInstances
# =============================================================================
#
# [Project Overview]
# RhinocerosのLoftツールを模倣し、位置・形状が異なる2つのコンポーネント（A, B）を
# 選択し、指定した分割数（steps）でその間を「形状補間」しながら埋めるツール。
#
# [Development Phases]
# Phase 1: 選択オブジェクトからの頂点データ（ワールド座標系）の抽出         [完了]
# Phase 2: 頂点数が異なる場合の対応付け（マッピング/リサンプリング）ロジック [完了]
# Phase 3: 補間（Tweening）による中間ジオメトリの生成とEntitiesへの描画     ← 現在
# Phase 4: UI（入力ボックス）の実装とUndo管理（start_operation）の統合
#
# [Phase 2 Algorithm Overview]
# Step 1 - Angular Sort:
#   Newell法で点群の法線を推定し、重心まわりの角度で頂点を反時計回りに整列する。
#   これにより、頂点順序の不整合から生じるLoftの「ねじれ」を抑制する。
#
# Step 2 - Arc-length Resampling:
#   頂点数が少ない側の閉ループを周長沿いに均等補間し、多い側の頂点数に揃える。
#   これにより、形状が異なる2つのシルエットを同じ頂点数で比較できるようにする。
#
# Step 3 - Rotation Alignment:
#   B配列の循環シフト（回転オフセット）を全パターン試し、A との距離コストの
#   合計が最小になるシフト量を採用する。これがLoftの「開始点」を揃える役割を担う。
#
# [Phase 3 Algorithm Overview]
# Step 1 - build_sections:
#   pairs と steps から (steps+2) 個の断面リングを線形補間で生成する。
#   sections[0] = A断面、sections[steps+1] = B断面、間は均等補間。
#
# Step 2 - add_section_face (cap):
#   各断面の頂点群から Face を生成。平面性が確保できない場合は重心から
#   ファン三角化（fan triangulation）でフォールバックする。
#
# Step 3 - stitch_sections (loft skin):
#   隣接断面リング間の対応頂点をQuadで接続。非平面Quadは2つのTriに分割。
#   これが Loft の「側面」= 真のサーフェスとなる。
#
# [Usage - Phase 3]
# 1. SketchUp で2つの ComponentInstance を選択する
# 2. Ruby コンソールで:
#      load '/path/to/su_bridgeloft.rb'      # Phase 3 まで一括実行（steps=4）
#    または
#      SuBridgeLoft::Phase3.run(steps: 6)   # steps を指定
#    または、pairs を直接渡す場合:
#      SuBridgeLoft::Phase3.generate_morphs(pairs, steps: 4)
#
# =============================================================================

module SuBridgeLoft

  # SketchUp内部単位(inches)での幾何的同一判定しきい値 — 全フェーズ共有
  TOLERANCE = 1.0e-6

  # ===========================================================================
  # Phase 1: ワールド座標系への頂点抽出
  # ===========================================================================
  module Phase1

    # 選択中の2つのComponentInstanceから頂点をワールド座標で抽出し、コンソールに出力する
    def self.extract_vertices
      model     = Sketchup.active_model
      selection = model.selection

      # --- 1. 選択から ComponentInstance を2つ取得 ---
      instances = selection.select { |e| e.is_a?(Sketchup::ComponentInstance) }

      if instances.length < 2
        puts "[BridgeLoft] Error: Please select exactly 2 ComponentInstances."
        puts "             Selected ComponentInstances: #{instances.length}"
        return nil
      end

      if instances.length > 2
        puts "[BridgeLoft] Warning: #{instances.length} ComponentInstances selected. Using the first two."
        instances = instances.first(2)
      end

      comp_a, comp_b = instances

      # --- 2 & 3. 各インスタンスの頂点をワールド座標系で抽出 ---
      vertices_a = world_vertices(comp_a)
      vertices_b = world_vertices(comp_b)

      # --- 4. 結果をコンソールに出力 ---
      puts ""
      puts "===== [BridgeLoft Phase 1] Vertex Extraction Results ====="
      puts ""
      puts "--- Component A: #{comp_a.definition.name} ---"
      puts "  Vertex count: #{vertices_a.length}"
      vertices_a.each_with_index do |pt, i|
        puts format("  [%3d] (%.4f, %.4f, %.4f)", i, pt.x.to_f, pt.y.to_f, pt.z.to_f)
      end

      puts ""
      puts "--- Component B: #{comp_b.definition.name} ---"
      puts "  Vertex count: #{vertices_b.length}"
      vertices_b.each_with_index do |pt, i|
        puts format("  [%3d] (%.4f, %.4f, %.4f)", i, pt.x.to_f, pt.y.to_f, pt.z.to_f)
      end

      puts ""
      puts "=========================================================="
      puts ""

      { comp_a: vertices_a, comp_b: vertices_b }
    end

    # ComponentInstance の Definition 内の全頂点をワールド座標に変換して返す
    #
    # @param instance [Sketchup::ComponentInstance]
    # @return [Array<Geom::Point3d>]
    def self.world_vertices(instance)
      transform = instance.transformation
      vertices  = []
      collect_vertices(instance.definition.entities, transform, vertices)
      unique_vertices(vertices)
    end

    # エンティティセットを再帰的に走査して頂点を収集する（ネストしたコンポーネントにも対応）
    #
    # @param entities  [Sketchup::Entities]
    # @param transform [Geom::Transformation]  現在の累積変換行列
    # @param out       [Array<Geom::Point3d>]  収集先の配列
    def self.collect_vertices(entities, transform, out)
      entities.each do |entity|
        case entity
        when Sketchup::Edge
          out << entity.start.position.transform(transform)
          out << entity.end.position.transform(transform)

        when Sketchup::Face
          entity.outer_loop.vertices.each do |v|
            out << v.position.transform(transform)
          end

        when Sketchup::ComponentInstance, Sketchup::Group
          child_transform = transform * entity.transformation
          child_entities  = entity.is_a?(Sketchup::Group) ?
                            entity.entities :
                            entity.definition.entities
          collect_vertices(child_entities, child_transform, out)
        end
      end
    end

    # 同一座標（TOLERANCE以内）の頂点を除去する
    def self.unique_vertices(points)
      result = []
      points.each do |pt|
        next if result.any? { |r|
          (r.x.to_f - pt.x.to_f).abs < TOLERANCE &&
          (r.y.to_f - pt.y.to_f).abs < TOLERANCE &&
          (r.z.to_f - pt.z.to_f).abs < TOLERANCE
        }
        result << pt
      end
      result
    end

  end # module Phase1


  # ===========================================================================
  # Phase 2: 頂点マッピング（Angular Sort → Resample → Alignment）
  # ===========================================================================
  module Phase2

    # -------------------------------------------------------------------------
    # Public API
    # -------------------------------------------------------------------------

    # 選択から Phase1 のデータを取得し、マッピングを実行してログを出力する。
    # Phase 1 → Phase 2 の一括実行エントリポイント。
    #
    # @return [Array<Hash{a: Geom::Point3d, b: Geom::Point3d}>] ペア配列
    def self.run
      data = Phase1.extract_vertices
      return nil unless data

      map_vertices(data[:comp_a], data[:comp_b])
    end

    # 2つの点群をマッピングしてペア配列を返す。
    # ログ出力も行うため、コンソールでの動作確認に使用できる。
    #
    # @param pts_a [Array<Geom::Point3d>]
    # @param pts_b [Array<Geom::Point3d>]
    # @return [Array<Hash{a: Geom::Point3d, b: Geom::Point3d}>]
    def self.map_vertices(pts_a, pts_b)
      if pts_a.empty? || pts_b.empty?
        puts "[BridgeLoft] Error: Empty vertex array passed to map_vertices."
        return []
      end

      # Step 1: Angular Sort — 各点群を重心まわりの角度で整列
      sorted_a = angular_sort(pts_a)
      sorted_b = angular_sort(pts_b)

      # Step 2: Arc-length Resample — 少ない方を多い方の頂点数に合わせる
      target_n  = [sorted_a.length, sorted_b.length].max
      rsmp_a    = resample(sorted_a, target_n)
      rsmp_b    = resample(sorted_b, target_n)

      # Step 3: Rotation Alignment — 距離コストが最小になる循環シフトを探す
      offset    = best_alignment_offset(rsmp_a, rsmp_b)
      aligned_b = rotate_array(rsmp_b, offset)

      # ペア配列を生成してログ出力
      pairs = rsmp_a.zip(aligned_b).map { |a, b| { a: a, b: b } }
      log_pairs(pairs, pts_a.length, pts_b.length, target_n, offset)

      pairs
    end

    # -------------------------------------------------------------------------
    # Step 1: Angular Sort
    # -------------------------------------------------------------------------

    # 点群を重心まわりの角度（反時計回り）でソートして返す。
    # Newell法で点群の最良適合平面法線を推定し、その平面への射影角でソート。
    #
    # @param points [Array<Geom::Point3d>]
    # @return [Array<Geom::Point3d>]
    def self.angular_sort(points)
      return points.dup if points.length < 3

      cen    = centroid(points)
      normal = estimate_normal(points)

      # u_axis: points[0] → 重心へのベクトルを平面に射影してローカルX軸とする
      u_axis = projected_unit_vector(points[0] - cen, normal)

      # u_axis が縮退した場合は別の点で試みる
      if u_axis.nil?
        fallback = points.find { |p| projected_unit_vector(p - cen, normal) }
        return points.dup if fallback.nil?
        u_axis = projected_unit_vector(fallback - cen, normal)
      end

      # v_axis: 法線 × u_axis = ローカルY軸（右手系）
      v_axis = normal.cross(u_axis)

      points.sort_by do |pt|
        vec    = pt - cen
        u_comp = dot3(vec, u_axis)
        v_comp = dot3(vec, v_axis)
        Math.atan2(v_comp, u_comp)
      end
    end

    # Newell法で点群の最良適合平面法線（単位ベクトル）を推定する。
    # 各連続辺のクロス積和を取るため、凸/非凸・3D点群のどちらにも有効。
    #
    # @param points [Array<Geom::Point3d>]
    # @return [Geom::Vector3d] 正規化済み法線ベクトル
    def self.estimate_normal(points)
      n  = points.length
      nx = 0.0; ny = 0.0; nz = 0.0

      n.times do |i|
        c = points[i]
        e = points[(i + 1) % n]
        # Newell's formula: 各辺から法線成分を累積
        nx += (c.y.to_f - e.y.to_f) * (c.z.to_f + e.z.to_f)
        ny += (c.z.to_f - e.z.to_f) * (c.x.to_f + e.x.to_f)
        nz += (c.x.to_f - e.x.to_f) * (c.y.to_f + e.y.to_f)
      end

      len = Math.sqrt(nx * nx + ny * ny + nz * nz)
      # 縮退した場合（点が一直線上など）はZ軸にフォールバック
      return Geom::Vector3d.new(0, 0, 1) if len < 1e-10

      Geom::Vector3d.new(nx / len, ny / len, nz / len)
    end

    # 点群の重心を返す
    #
    # @param points [Array<Geom::Point3d>]
    # @return [Geom::Point3d]
    def self.centroid(points)
      n = points.length.to_f
      Geom::Point3d.new(
        points.sum { |p| p.x.to_f } / n,
        points.sum { |p| p.y.to_f } / n,
        points.sum { |p| p.z.to_f } / n
      )
    end

    # ベクトル vec を平面（法線 normal）に射影して正規化する。
    # 縮退（平面と平行）の場合は nil を返す。
    #
    # @param vec    [Geom::Vector3d]
    # @param normal [Geom::Vector3d] 単位ベクトルであること
    # @return [Geom::Vector3d, nil]
    def self.projected_unit_vector(vec, normal)
      n_comp = dot3(vec, normal)
      proj   = Geom::Vector3d.new(
        vec.x.to_f - n_comp * normal.x.to_f,
        vec.y.to_f - n_comp * normal.y.to_f,
        vec.z.to_f - n_comp * normal.z.to_f
      )
      len = proj.length.to_f
      return nil if len < 1e-10
      Geom::Vector3d.new(proj.x.to_f / len, proj.y.to_f / len, proj.z.to_f / len)
    end

    # 2つのベクトルのドット積（Float）を返す汎用ヘルパー
    def self.dot3(a, b)
      a.x.to_f * b.x.to_f +
      a.y.to_f * b.y.to_f +
      a.z.to_f * b.z.to_f
    end

    # -------------------------------------------------------------------------
    # Step 2: Arc-length Resampling
    # -------------------------------------------------------------------------

    # 閉ループの点群を周長（arc-length）に沿って target_count 個に均等再サンプリングする。
    # 元の点の位置は保持されず、周長上の等間隔位置を線形補間で求める。
    #
    # @param points       [Array<Geom::Point3d>]
    # @param target_count [Integer]
    # @return [Array<Geom::Point3d>]
    def self.resample(points, target_count)
      return points.dup if points.length == target_count

      n = points.length
      return Array.new(target_count, points[0]) if n < 2

      # 各辺の長さと累積弧長を計算（閉ループ: 最後の点→先頭の点も含む）
      seg_lengths = Array.new(n) { |i|
        points[i].distance(points[(i + 1) % n]).to_f
      }
      cum = [0.0]
      seg_lengths.each { |s| cum << cum.last + s }
      total = cum.last

      return points.dup if total < 1e-10

      Array.new(target_count) do |k|
        # k 番目の点を配置する目標弧長位置
        target_dist = total * k.to_f / target_count

        # 二分探索で対応セグメントを特定
        seg_idx = binary_search_segment(cum, target_dist, n)

        seg_len = seg_lengths[seg_idx]
        if seg_len < 1e-10
          points[seg_idx]
        else
          t = (target_dist - cum[seg_idx]) / seg_len
          t = t.clamp(0.0, 1.0)
          lerp_point(points[seg_idx], points[(seg_idx + 1) % n], t)
        end
      end
    end

    # 累積弧長配列 cum の中から target_dist を含むセグメントインデックスを二分探索で返す
    def self.binary_search_segment(cum, target_dist, n)
      lo = 0; hi = n - 1
      while lo < hi
        mid = (lo + hi) / 2
        if cum[mid + 1] < target_dist
          lo = mid + 1
        else
          hi = mid
        end
      end
      lo
    end

    # 2点間の線形補間
    def self.lerp_point(a, b, t)
      Geom::Point3d.new(
        a.x.to_f + t * (b.x.to_f - a.x.to_f),
        a.y.to_f + t * (b.y.to_f - a.y.to_f),
        a.z.to_f + t * (b.z.to_f - a.z.to_f)
      )
    end

    # -------------------------------------------------------------------------
    # Step 3: Rotation Alignment
    # -------------------------------------------------------------------------

    # pts_b を循環シフトしたときの pts_a との二乗距離合計を全シフト量で計算し、
    # コストが最小になるシフト量（offset）を返す。
    # 計算量: O(n²) — 実用的な頂点数（~数百）では十分高速。
    #
    # @param pts_a [Array<Geom::Point3d>]
    # @param pts_b [Array<Geom::Point3d>] pts_a と同じ長さであること
    # @return [Integer] 最適シフト量
    def self.best_alignment_offset(pts_a, pts_b)
      n           = pts_a.length
      best_offset = 0
      best_cost   = Float::INFINITY

      n.times do |offset|
        cost = 0.0
        n.times do |i|
          d = pts_a[i].distance(pts_b[(i + offset) % n]).to_f
          cost += d * d
        end
        if cost < best_cost
          best_cost   = cost
          best_offset = offset
        end
      end

      best_offset
    end

    # 配列を offset だけ循環シフトして返す
    # （例: [A,B,C,D], offset=1 → [B,C,D,A]）
    #
    # @param arr    [Array]
    # @param offset [Integer]
    # @return [Array]
    def self.rotate_array(arr, offset)
      return arr.dup if arr.empty? || offset == 0
      n      = arr.length
      offset = offset % n
      arr[offset..] + arr[0...offset]
    end

    # -------------------------------------------------------------------------
    # Logging
    # -------------------------------------------------------------------------

    # ペアリング結果をコンソールに見やすく出力する
    #
    # @param pairs    [Array<Hash{a: Geom::Point3d, b: Geom::Point3d}>]
    # @param n_a      [Integer] A の元の頂点数
    # @param n_b      [Integer] B の元の頂点数
    # @param target_n [Integer] リサンプリング後の統一頂点数
    # @param offset   [Integer] 採用した B の循環シフト量
    def self.log_pairs(pairs, n_a, n_b, target_n, offset)
      puts ""
      puts "===== [BridgeLoft Phase 2] Vertex Mapping Results ====="
      puts ""
      puts "  [Input]"
      puts "    Component A vertices (original): #{n_a}"
      puts "    Component B vertices (original): #{n_b}"
      puts "    Unified count after resampling : #{target_n}"
      puts "    Best alignment offset (B shift): #{offset}"
      puts ""
      puts "  [Pairs]  A[idx] position -> B[idx] position  (distance)"
      puts "  " + "-" * 60

      total_dist = 0.0
      pairs.each_with_index do |pair, i|
        a    = pair[:a]
        b    = pair[:b]
        dist = a.distance(b).to_f
        total_dist += dist
        puts format("  A[%3d] (%8.3f, %8.3f, %8.3f) ->" \
                    " B[%3d] (%8.3f, %8.3f, %8.3f)  dist: %.4f\"",
                    i, a.x.to_f, a.y.to_f, a.z.to_f,
                    i, b.x.to_f, b.y.to_f, b.z.to_f,
                    dist)
      end

      puts "  " + "-" * 60
      avg_dist = total_dist / [pairs.length, 1].max
      puts format("  Total distance: %.4f\"   Average per pair: %.4f\"",
                  total_dist, avg_dist)
      puts ""
      puts "======================================================="
      puts ""
    end

  end # module Phase2


  # ===========================================================================
  # Phase 3: 補間ジオメトリの生成（Morphing & Loft Skin）
  # ===========================================================================
  module Phase3

    # 生成されるトップレベルグループの名前（既存があれば置き換える）
    RESULT_GROUP_NAME = 'su_bridgeloft_result'

    # -------------------------------------------------------------------------
    # Public API
    # -------------------------------------------------------------------------

    # Phase 1 → 2 → 3 を一括実行するエントリポイント。
    #
    # @param steps [Integer] 中間断面の数（AとBは含まない）
    # @return [Array<Sketchup::Group>] 生成された断面グループの配列
    def self.run(steps: 4)
      pairs = Phase2.run
      return [] unless pairs && !pairs.empty?

      generate_morphs(pairs, steps: steps)
    end

    # Phase 2 の pairs を受け取り、SketchUp 上に Loft ジオメトリを生成する。
    #
    # グループ構造:
    #   su_bridgeloft_result (親グループ)
    #   ├── section_00  (A断面 cap)
    #   ├── section_01  (補間断面 cap)
    #   │   ...
    #   ├── section_NN  (B断面 cap)
    #   └── loft_skin   (全側面 Quad/Tri)
    #
    # @param pairs [Array<Hash{a: Geom::Point3d, b: Geom::Point3d}>]
    # @param steps [Integer] 中間断面の数
    # @return [Array<Sketchup::Group>] 断面グループの配列（loft_skin は含まない）
    def self.generate_morphs(pairs, steps: 4)
      if pairs.empty?
        puts "[BridgeLoft] Error: pairs is empty. Aborting Phase 3."
        return []
      end

      model = Sketchup.active_model
      model.start_operation('su_bridgeloft', true)

      begin
        # 親グループを取得（既存があれば削除して作り直す）
        parent_group = reset_result_group(model.entities)
        p_ents       = parent_group.entities

        # ---- Step 1: 全断面リングを生成 ----
        # sections[0] = A, sections[1..steps] = 中間, sections[steps+1] = B
        sections = build_sections(pairs, steps)
        total_sections = sections.length  # = steps + 2

        # ---- Step 2: 各断面に cap フェースを追加 ----
        section_groups = sections.map.with_index do |ring, idx|
          grp      = p_ents.add_group
          grp.name = format('section_%02d', idx)
          add_section_face(grp.entities, ring)
          grp
        end

        # ---- Step 3: 隣接断面間に側面（Loft Skin）を張る ----
        skin_group      = p_ents.add_group
        skin_group.name = 'loft_skin'
        faces_created   = stitch_sections(skin_group.entities, sections)

        model.commit_operation

        log_result(steps, total_sections, section_groups.length, faces_created)
        section_groups

      rescue => e
        model.abort_operation
        puts "[BridgeLoft] Error in Phase 3: #{e.message}"
        puts e.backtrace.first(5).join("\n")
        []
      end
    end

    # -------------------------------------------------------------------------
    # Step 1: 断面リングの生成
    # -------------------------------------------------------------------------

    # pairs から (steps + 2) 個の断面リング配列を線形補間で構築する。
    # t = 0.0 が A 断面、t = 1.0 が B 断面、間は均等分割。
    #
    # @param pairs [Array<Hash{a: Point3d, b: Point3d}>]
    # @param steps [Integer]
    # @return [Array<Array<Geom::Point3d>>] 断面ごとの頂点リスト
    def self.build_sections(pairs, steps)
      total = steps + 2  # A + 中間 + B

      Array.new(total) do |s|
        t = s.to_f / (total - 1)  # 0.0 ... 1.0
        pairs.map { |pair| Phase2.lerp_point(pair[:a], pair[:b], t) }
      end
    end

    # -------------------------------------------------------------------------
    # Step 2: Cap フェースの追加
    # -------------------------------------------------------------------------

    # 断面の頂点リングから閉じた Face を生成する。
    # 非平面の場合は重心からのファン三角化にフォールバックする。
    #
    # @param entities [Sketchup::Entities]
    # @param ring     [Array<Geom::Point3d>]
    def self.add_section_face(entities, ring)
      return if ring.length < 3

      # まず全頂点で単一フェースを試みる
      return if try_add_face(entities, ring)

      # フォールバック: 重心からファン三角化
      cen = Phase2.centroid(ring)
      n   = ring.length
      n.times do |i|
        try_add_face(entities, [cen, ring[i], ring[(i + 1) % n]])
      end
    end

    # -------------------------------------------------------------------------
    # Step 3: 側面（Loft Skin）の生成
    # -------------------------------------------------------------------------

    # 隣接する断面リングのペアに対して Quad 側面を張る。
    # Quad が非平面の場合は2つの Triangle に分割する。
    #
    # Quad の頂点順序（外向き法線が一貫するよう右ねじ方向を維持）:
    #   ring_prev[j] → ring_prev[j+1] → ring_next[j+1] → ring_next[j]
    #
    # @param entities [Sketchup::Entities]
    # @param sections [Array<Array<Geom::Point3d>>]
    # @return [Integer] 実際に生成されたフェース数
    def self.stitch_sections(entities, sections)
      n_pts        = sections[0].length
      faces_count  = 0

      sections.each_cons(2) do |ring_prev, ring_next|
        n_pts.times do |j|
          j1 = (j + 1) % n_pts

          a = ring_prev[j]   # 現断面 左
          b = ring_prev[j1]  # 現断面 右
          c = ring_next[j1]  # 次断面 右
          d = ring_next[j]   # 次断面 左

          if try_add_face(entities, [a, b, c, d])
            faces_count += 1
          else
            # Quad が縮退または非平面 → 2 Triangle に分割
            faces_count += 1 if try_add_face(entities, [a, b, d])
            faces_count += 1 if try_add_face(entities, [b, c, d])
          end
        end
      end

      faces_count
    end

    # -------------------------------------------------------------------------
    # Geometry Utilities
    # -------------------------------------------------------------------------

    # Sketchup::Entities#add_face の安全ラッパー。
    # 生成に失敗した場合（ArgumentError, 縮退, nil 返却）は nil を返す。
    #
    # @param entities [Sketchup::Entities]
    # @param pts      [Array<Geom::Point3d>] 3点以上
    # @return [Sketchup::Face, nil]
    def self.try_add_face(entities, pts)
      return nil if pts.length < 3

      # 縮退チェック: 全点が同一または直線上にある場合はスキップ
      return nil if degenerate_polygon?(pts)

      begin
        result = entities.add_face(pts)
        result.is_a?(Sketchup::Face) ? result : nil
      rescue ArgumentError, RuntimeError
        nil
      end
    end

    # 頂点リストが縮退しているか判定する（面積ゼロ = ゼロベクトルのクロス積）
    #
    # @param pts [Array<Geom::Point3d>]
    # @return [Boolean]
    def self.degenerate_polygon?(pts)
      # 最初の非ゼロ辺ベクトルを基準に面積を推定
      area2 = 0.0
      origin = pts[0]
      (2...pts.length).each do |i|
        v1 = pts[i - 1] - origin
        v2 = pts[i]     - origin
        # クロス積の長さ = 平行四辺形面積
        cx = v1.y.to_f * v2.z.to_f - v1.z.to_f * v2.y.to_f
        cy = v1.z.to_f * v2.x.to_f - v1.x.to_f * v2.z.to_f
        cz = v1.x.to_f * v2.y.to_f - v1.y.to_f * v2.x.to_f
        area2 += Math.sqrt(cx * cx + cy * cy + cz * cz)
      end
      area2 < TOLERANCE
    end

    # 既存の結果グループを削除して新しいグループを返す
    #
    # @param entities [Sketchup::Entities] model.entities
    # @return [Sketchup::Group]
    def self.reset_result_group(entities)
      existing = entities.grep(Sketchup::Group)
                         .select { |g| g.name == RESULT_GROUP_NAME }
      unless existing.empty?
        puts "[BridgeLoft] Replacing existing '#{RESULT_GROUP_NAME}' group."
        entities.erase_entities(existing)
      end
      grp      = entities.add_group
      grp.name = RESULT_GROUP_NAME
      grp
    end

    # -------------------------------------------------------------------------
    # Logging
    # -------------------------------------------------------------------------

    def self.log_result(steps, total_sections, n_section_groups, faces_created)
      puts ""
      puts "===== [BridgeLoft Phase 3] Geometry Generation Complete ====="
      puts "  Intermediate steps     : #{steps}"
      puts "  Total sections (A+mid+B): #{total_sections}"
      puts "  Section cap groups     : #{n_section_groups}"
      puts "  Loft skin faces        : #{faces_created}"
      puts "  Parent group           : '#{RESULT_GROUP_NAME}'"
      puts "  → Undo with Ctrl+Z to remove all generated geometry."
      puts "============================================================="
      puts ""
    end

  end # module Phase3

end # module SuBridgeLoft

# スクリプトを直接 load した場合は Phase 3 まで一括実行（steps=4）
SuBridgeLoft::Phase3.run(steps: 4)
