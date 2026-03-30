# =============================================================================
# su_bridgeloft - SketchUp Plugin: Loft between two ComponentInstances
# =============================================================================
#
# [Project Overview]
# RhinocerosのLoftツールを模倣し、位置・形状が異なる2つのコンポーネント（A, B）を
# 選択し、指定した分割数（steps）でその間を「形状補間」しながら埋めるツール。
#
# [Development Phases]
# Phase 1: 選択オブジェクトからの頂点データ（ワールド座標系）の抽出  ← 現在
# Phase 2: 頂点数が異なる場合の対応付け（マッピング/リサンプリング）ロジック
# Phase 3: 補間（Tweening）による中間ジオメトリの生成とEntitiesへの描画
# Phase 4: UI（入力ボックス）の実装とUndo管理（start_operation）の統合
#
# [Usage - Phase 1]
# 1. SketchUp で2つの ComponentInstance を選択する
# 2. Ruby コンソールで以下を実行:
#      load '/path/to/su_bridgeloft.rb'
#    または
#      SuBridgeLoft::Phase1.extract_vertices
#
# =============================================================================

module SuBridgeLoft
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
      puts "==========================================================
"

      # 呼び出し元でも使えるよう結果を返す
      { comp_a: vertices_a, comp_b: vertices_b }
    end

    # ComponentInstance の Definition 内の全頂点をワールド座標に変換して返す
    #
    # @param instance [Sketchup::ComponentInstance]
    # @return [Array<Geom::Point3d>]
    def self.world_vertices(instance)
      transform = instance.transformation
      vertices  = []

      # Definition 内のエンティティを再帰的に走査し、Edge の端点（Vertex）を収集
      collect_vertices(instance.definition.entities, transform, vertices)

      # 重複頂点を除去（同一座標を持つ Vertex は1つにまとめる）
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
          # Edge の両端点をワールド座標に変換して追加
          out << entity.start.position.transform(transform)
          out << entity.end.position.transform(transform)

        when Sketchup::Face
          # Face のループから頂点を取得（Edge との重複は後段の unique_vertices で解消）
          entity.outer_loop.vertices.each do |v|
            out << v.position.transform(transform)
          end

        when Sketchup::ComponentInstance, Sketchup::Group
          # ネストした ComponentInstance / Group は変換を累積して再帰
          child_transform = transform * entity.transformation
          child_entities  = entity.is_a?(Sketchup::Group) ?
                            entity.entities :
                            entity.definition.entities
          collect_vertices(child_entities, child_transform, out)
        end
      end
    end

    # 同一座標（SketchUp の内部単位 inches で比較）の頂点を除去する
    #
    # @param points [Array<Geom::Point3d>]
    # @return [Array<Geom::Point3d>]
    TOLERANCE = 1.0e-6  # inches

    def self.unique_vertices(points)
      result = []
      points.each do |pt|
        duplicate = result.any? do |r|
          (r.x - pt.x).abs < TOLERANCE &&
          (r.y - pt.y).abs < TOLERANCE &&
          (r.z - pt.z).abs < TOLERANCE
        end
        result << pt unless duplicate
      end
      result
    end

  end # module Phase1
end # module SuBridgeLoft

# スクリプトを直接 load した場合は即実行
SuBridgeLoft::Phase1.extract_vertices
