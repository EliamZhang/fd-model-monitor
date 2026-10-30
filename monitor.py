"""同步老客模型周度 AUC、转化率与分箱坏账率，并生成自包含的 HTML 监控看板。

用法（线上环境，脚本同目录需有提供 query_to_df(sql) 的 hive_config）：
    python monitor.py
    python monitor.py --from-csv 原始数据/model_monitor_auc.csv   # 不连库，用已导出的结果重建看板

流程：
    1. 读取 fundo_model_monitor.sql，按分号拆成语句依次执行（DROP / CREATE / 可选 SELECT）
    2. 没有 SELECT 语句时，自动 SELECT * FROM CREATE 出来的每张表
    3. 结果分别写入 原始数据/ 下的 model_monitor_auc.csv、model_monitor_funnel.csv、
       model_monitor_bin.csv、model_monitor_score_dist.csv，并一起打包成 model_monitor_data.zip
    4. 生成根目录下的 model_monitor_dashboard.html（数据内嵌，离线可开）
"""

import argparse
import json
import re
import sys
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pandas as pd

from sync import split_statements


if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")


PROJECT_DIR = Path(__file__).resolve().parent
SQL_FILE = PROJECT_DIR / "fundo_model_monitor.sql"
CSV_FILE = PROJECT_DIR / "原始数据" / "model_monitor_auc.csv"
FUNNEL_CSV_FILE = PROJECT_DIR / "原始数据" / "model_monitor_funnel.csv"
BIN_CSV_FILE = PROJECT_DIR / "原始数据" / "model_monitor_bin.csv"
DIST_CSV_FILE = PROJECT_DIR / "原始数据" / "model_monitor_score_dist.csv"
ZIP_FILE = PROJECT_DIR / "model_monitor_data.zip"
HTML_FILE = PROJECT_DIR / "model_monitor_dashboard.html"
BUSINESS_TZ = timezone(timedelta(hours=8))

LABELS = [
    ("fpd7_flag", "FPD7"),
    ("duedate_1m_5", "首期 5+"),
    ("duedate_1m_30", "首期 30+"),
    ("duedate_2m_30", "2 期 30+"),
    ("duedate_3m_30", "3 期 30+"),
]

# (模型分字段, 展示用家族名, 版本, 分箱阈值[箱1-4上限])。版本用于 1.1 / 1.2 对比切换。
# mltmodel = 融合主模型；submodel = 银行流水子模型；appmodel = 行为子模型。
MODELS = [
    ("old_risk_bid_submodel_250909_txn", "submodel 银行流水子模型", "1.1",
     [0.052011, 0.07337, 0.099983, 0.14444]),
    ("aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score", "submodel 银行流水子模型", "1.2",
     [0.045117, 0.063512, 0.087708, 0.130728]),
    ("old_risk_bid_mltmodel_v1_1_20251021", "mltmodel 融合主模型", "1.1",
     [0.039873, 0.057702, 0.089551, 0.149927]),
    ("old_risk_bid_mltmodel_v1_2_20260325", "mltmodel 融合主模型", "1.2",
     [0.035078, 0.054394, 0.081105, 0.132466]),
    ("old_risk_bid_appmodel_v1_1_20250911", "appmodel 行为子模型", "1.1",
     [0.051164, 0.071347, 0.095801, 0.138524]),
    ("aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score", "appmodel 行为子模型", "1.2",
     [0.051725, 0.069226, 0.090624, 0.1212]),
]

_UNFUNDED = "UNFUNDED"
# 已表现样本量低于历史常规水平的这个比例时，视为「样本未成熟」
MATURITY_THRESHOLD = 0.75
_NATURAL_RE = re.compile(r"(\d+)")
_WEEK_RE = re.compile(r"^(\d{4})-?W(\d{2})$", re.I)
_CREATE_RE = re.compile(
    r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([A-Za-z0-9_.]+)", re.I
)


def week_start_date(text):
    """把 2026W42 这类 ISO 周标记换算成该周周一的日期字符串。"""
    match = _WEEK_RE.match(str(text).strip())
    if not match:
        return None
    try:
        return datetime.strptime(
            f"{int(match.group(1))} {int(match.group(2))} 1", "%G %V %u"
        ).date().isoformat()
    except ValueError:
        return None


def now():
    return datetime.now(BUSINESS_TZ)


def natural_key(text):
    return [(0, int(part)) if part.isdigit() else (1, part)
            for part in _NATURAL_RE.split(str(text))]


def first_line(sql, width=90):
    line = " ".join(sql.split())
    return line[:width] + ("…" if len(line) > width else "")


def run_sql_file(query_fn):
    """按顺序执行 SQL 文件中的语句，返回 [(表名或 None, DataFrame), ...]。"""
    statements = split_statements(SQL_FILE.read_text(encoding="utf-8"))
    if not statements:
        raise ValueError(f"{SQL_FILE.name} 中没有可执行语句")

    targets = []
    results = []
    for index, statement in enumerate(statements, start=1):
        print(f"执行 [{index}/{len(statements)}] | {first_line(statement)}")
        match = _CREATE_RE.search(statement)
        if match:
            targets.append(match.group(1))
        output = query_fn(statement)
        if isinstance(output, pd.DataFrame) and len(output.columns) > 0:
            results.append((None, output))

    if not results:
        if not targets:
            raise ValueError("SQL 文件里既没有 SELECT 结果，也没能解析出 CREATE TABLE 的目标表名")
        for table in targets:
            pull_sql = f"SELECT * FROM {table}"
            print(f"拉取结果 | {pull_sql}")
            results.append((table, query_fn(pull_sql)))

    return results


def pick_result(results, keyword, fallback_index):
    for name, frame in results:
        if name and keyword in name.lower():
            return frame, name
    if len(results) > fallback_index:
        return results[fallback_index][1], results[fallback_index][0]
    return None, None


def load_result(path):
    print(f"读取本地结果 | {path}")
    return pd.read_csv(path, encoding="utf-8-sig")


def write_zip(csv_paths):
    """把结果 CSV 按 原始数据/ 目录结构打包，方便整包拉回本地。"""
    temporary = ZIP_FILE.with_suffix(".zip.tmp")
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("原始数据/", "")
        for csv_path in csv_paths:
            archive.write(csv_path, f"原始数据/{csv_path.name}")
    temporary.replace(ZIP_FILE)


def build_payload(df):
    if df is None:
        return {
            "generatedAt": now().isoformat(timespec="seconds"),
            "labels": [],
            "models": [],
            "weeks": [],
            "rows": {},
            "maturity": {},
            "maturityThreshold": MATURITY_THRESHOLD,
        }
    required = {
        "time_key", "label_name", "model_name", "auc",
        "total_application_cnt", "performance_cnt", "pos_cnt", "neg_cnt",
    }
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"结果缺少字段：{', '.join(sorted(missing))}")

    df = df.copy()
    df["time_key"] = df["time_key"].astype(str)
    df = df[df["time_key"].str.upper() != _UNFUNDED]
    df["time_key"] = df["time_key"].map(lambda value: week_start_date(value) or value)

    weeks = sorted(df["time_key"].unique(), key=natural_key)
    label_keys = [key for key, _ in LABELS]
    model_keys = [key for key, _, _, _ in MODELS]
    labels = [key for key in label_keys if key in set(df["label_name"])]
    labels += sorted(set(df["label_name"]) - set(labels))
    models = [key for key in model_keys if key in set(df["model_name"])]
    models += sorted(set(df["model_name"]) - set(models))
    model_meta = {key: (family, version) for key, family, version, _ in MODELS}

    def number(value):
        return None if pd.isna(value) else float(value)

    def count(value):
        return None if pd.isna(value) else int(value)

    rows = {}
    for (label, week, model), group in df.groupby(
        ["label_name", "time_key", "model_name"], sort=False
    ):
        point = group.iloc[0]
        rows.setdefault(label, {}).setdefault(week, {})[model] = {
            "auc": number(point["auc"]),
            "total": count(point["total_application_cnt"]),
            "perf": count(point["performance_cnt"]),
            "pos": count(point["pos_cnt"]),
            "neg": count(point["neg_cnt"]),
        }

    # 成熟度 = 本周已表现样本 / 该标签历史常规表现量（最近 8 周不参与基准）
    counts = df.groupby(["label_name", "time_key"])["performance_cnt"].first()
    maturity = {}
    for label in df["label_name"].unique():
        series = counts.loc[label].reindex(weeks)
        valid = series.dropna()
        if valid.empty:
            continue
        baseline = valid.iloc[:-8].median() if len(valid) > 8 else valid.median()
        if pd.isna(baseline) or baseline <= 0:
            continue
        maturity[label] = {
            week: None if pd.isna(value) else round(min(float(value) / float(baseline), 1.0), 2)
            for week, value in series.items()
        }

    return {
        "generatedAt": now().isoformat(timespec="seconds"),
        "labels": [{"key": key, "name": dict(LABELS).get(key, key)} for key in labels],
        "models": [
            {
                "key": key,
                "name": model_meta.get(key, (key, ""))[0],
                "version": model_meta.get(key, (key, ""))[1],
            }
            for key in models
        ],
        "weeks": weeks,
        "rows": rows,
        "maturity": maturity,
        "maturityThreshold": MATURITY_THRESHOLD,
    }


def build_funnel_payload(df):
    if df is None or len(df) == 0:
        return None
    required = {"time_key", "application_cnt", "completed_cnt", "approved_cnt", "deal_cnt"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"转化结果缺少字段：{', '.join(sorted(missing))}")

    df = df.copy()
    df["time_key"] = df["time_key"].astype(str)
    df["time_key"] = df["time_key"].map(lambda value: week_start_date(value) or value)
    df = df[df["time_key"].str.lower() != "nan"]
    weeks = sorted(df["time_key"].unique(), key=natural_key)

    def integer(row, column):
        return int(row[column]) if column in row.index and pd.notna(row[column]) else None

    rows = {}
    for _, row in df.iterrows():
        rows[row["time_key"]] = {
            "apply": integer(row, "application_cnt"),
            "completed": integer(row, "completed_cnt"),
            "approved": integer(row, "approved_cnt"),
            "auto": integer(row, "auto_approved_cnt"),
            "manual": integer(row, "manual_approved_cnt"),
            "deal": integer(row, "deal_cnt"),
            "funded": integer(row, "funded_cnt"),
        }
    return {"weeks": weeks, "rows": rows}


def build_bin_payload(df):
    if df is None or len(df) == 0:
        return None
    required = {"time_key", "label_name", "model_name", "model_bin", "performance_cnt", "pos_cnt"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"分箱结果缺少字段：{', '.join(sorted(missing))}")

    df = df.copy()
    df["time_key"] = df["time_key"].astype(str)
    df["time_key"] = df["time_key"].map(lambda value: week_start_date(value) or value)
    df = df[df["time_key"].str.upper() != _UNFUNDED]
    weeks = sorted(df["time_key"].unique(), key=natural_key)

    rows = {}
    for _, row in df.iterrows():
        perf = int(row["performance_cnt"]) if pd.notna(row["performance_cnt"]) else None
        pos = int(row["pos_cnt"]) if pd.notna(row["pos_cnt"]) else None
        if perf is None and pos is None:
            continue
        rows.setdefault(row["label_name"], {}).setdefault(row["time_key"], {}).setdefault(
            row["model_name"], {}
        )[str(int(row["model_bin"]))] = {"perf": perf, "pos": pos}

    bin_labels = [key for key in ("fpd7_flag", "duedate_1m_30") if key in rows]
    return {
        "weeks": weeks,
        "labels": [{"key": key, "name": dict(LABELS).get(key, key)} for key in bin_labels],
        "thresholds": {key: limits for key, _, _, limits in MODELS},
        "rows": rows,
    }


def build_dist_payload(df):
    if df is None or len(df) == 0:
        return None
    required = {"time_key", "model_name", "model_bin", "application_cnt"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"分布结果缺少字段：{', '.join(sorted(missing))}")

    df = df.copy()
    df["time_key"] = df["time_key"].astype(str)
    df["time_key"] = df["time_key"].map(lambda value: week_start_date(value) or value)
    df = df[df["time_key"].str.lower() != "nan"]
    weeks = sorted(df["time_key"].unique(), key=natural_key)

    rows = {}
    for _, row in df.iterrows():
        rows.setdefault(row["time_key"], {}).setdefault(row["model_name"], {})[
            str(int(row["model_bin"]))
        ] = int(row["application_cnt"])

    return {
        "weeks": weeks,
        "thresholds": {key: limits for key, _, _, limits in MODELS},
        "rows": rows,
    }


def build_html(payload, source_name):
    payload = {**payload, "source": source_name or ""}
    data = json.dumps(payload, ensure_ascii=False)
    return HTML_TEMPLATE.replace("__DATA_JSON__", data)


def main(argv=None):
    parser = argparse.ArgumentParser(description="同步模型周度 AUC / 转化率 / 分箱坏账率并生成 HTML 看板")
    parser.add_argument("--from-csv", help="不连库，直接用已导出的 AUC 结果 CSV 生成看板")
    parser.add_argument("--funnel-csv", help="配合 --from-csv 的转化率结果 CSV；默认取同目录 model_monitor_funnel.csv")
    parser.add_argument("--bin-csv", help="配合 --from-csv 的分箱结果 CSV；默认取同目录 model_monitor_bin.csv")
    parser.add_argument("--dist-csv", help="配合 --from-csv 的分布结果 CSV；默认取同目录 model_monitor_score_dist.csv")
    args = parser.parse_args(argv)

    source_table = None
    if args.from_csv:
        df = load_result(Path(args.from_csv))
        base_dir = Path(args.from_csv).parent
        funnel_path = Path(args.funnel_csv) if args.funnel_csv else base_dir / FUNNEL_CSV_FILE.name
        bin_path = Path(args.bin_csv) if args.bin_csv else base_dir / BIN_CSV_FILE.name
        dist_path = Path(args.dist_csv) if args.dist_csv else base_dir / DIST_CSV_FILE.name
        funnel_df = load_result(funnel_path) if funnel_path.exists() else None
        if funnel_df is None:
            print(f"未找到转化数据 | {funnel_path}（看板将不显示转化区块）")
        bin_df = load_result(bin_path) if bin_path.exists() else None
        if bin_df is None:
            print(f"未找到分箱数据 | {bin_path}（看板将不显示分箱区块）")
        dist_df = load_result(dist_path) if dist_path.exists() else None
        if dist_df is None:
            print(f"未找到分布数据 | {dist_path}（看板将不显示分布区块）")
    else:
        try:
            from hive_config import query_to_df
        except ImportError:
            print("未找到 hive_config.py：请把提供 query_to_df(sql) 的模块放到本脚本同目录或 PYTHONPATH 中。")
            return 2
        results = run_sql_file(query_to_df)
        df, source_table = pick_result(results, "auc", 0)
        funnel_df, _ = pick_result(results, "funnel", 1)
        bin_df, _ = pick_result(results, "bin", 2)
        dist_df, _ = pick_result(results, "dist", 3)

    if df is None or len(df) == 0:
        print("警告 | AUC 查询结果为空，看板将显示空状态")

    if not args.from_csv:
        CSV_FILE.parent.mkdir(parents=True, exist_ok=True)
        written = []
        if df is not None:
            df.to_csv(CSV_FILE, index=False, encoding="utf-8-sig")
            written.append(CSV_FILE)
            print(f"已保存结果 | {CSV_FILE}（{len(df)} 行）")
        if funnel_df is not None:
            funnel_df.to_csv(FUNNEL_CSV_FILE, index=False, encoding="utf-8-sig")
            written.append(FUNNEL_CSV_FILE)
            print(f"已保存转化 | {FUNNEL_CSV_FILE}（{len(funnel_df)} 行）")
        if bin_df is not None:
            bin_df.to_csv(BIN_CSV_FILE, index=False, encoding="utf-8-sig")
            written.append(BIN_CSV_FILE)
            print(f"已保存分箱 | {BIN_CSV_FILE}（{len(bin_df)} 行）")
        if dist_df is not None:
            dist_df.to_csv(DIST_CSV_FILE, index=False, encoding="utf-8-sig")
            written.append(DIST_CSV_FILE)
            print(f"已保存分布 | {DIST_CSV_FILE}（{len(dist_df)} 行）")
        if written:
            write_zip(written)
            print(f"已打包 | {ZIP_FILE}")

    payload = build_payload(df)
    payload["funnel"] = build_funnel_payload(funnel_df)
    payload["bins"] = build_bin_payload(bin_df)
    payload["dist"] = build_dist_payload(dist_df)
    HTML_FILE.parent.mkdir(parents=True, exist_ok=True)
    HTML_FILE.write_text(build_html(payload, source_table), encoding="utf-8")
    print(f"已生成看板 | {HTML_FILE}")
    print(f"周数 {len(payload['weeks'])} | 标签 {len(payload['labels'])} | 模型 {len(payload['models'])}")
    if payload["funnel"]:
        print(f"转化周数 {len(payload['funnel']['weeks'])}")
    if payload["bins"]:
        print(f"分箱周数 {len(payload['bins']['weeks'])}")
    if payload["dist"]:
        print(f"分布周数 {len(payload['dist']['weeks'])}")
    return 0


HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Fundo 老客模型监控</title>
<style>
  :root {
    color-scheme: light;
    --page: #f9f9f7;
    --surface: #fcfcfb;
    --ink: #0b0b0b;
    --ink-2: #52514e;
    --muted: #898781;
    --grid: #e1e0d9;
    --axis: #c3c2b7;
    --border: rgba(11, 11, 11, 0.10);
    --series-1: #2a78d6;
    --series-2: #eb6834;
    --series-3: #1baf7a;
    --seq-0: #fce8e8;
    --seq-1: #f5b5b5;
    --seq-2: #e87676;
    --seq-3: #cf3b3b;
    --seq-4: #8e1d1d;
    --dist-1: #e29b9b;
    --dist-2: #d67474;
    --dist-3: #c34e4e;
    --dist-4: #a92d2d;
    --dist-5: #871919;
    --good: #006300;
    --bad: #d03b3b;
    --wash: rgba(11, 11, 11, 0.04);
    --band: rgba(137, 135, 129, 0.16);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      color-scheme: dark;
      --page: #0d0d0d;
      --surface: #1a1a19;
      --ink: #f0efec;
      --ink-2: #c3c2b7;
      --muted: #898781;
      --grid: #2c2c2a;
      --axis: #383835;
      --border: rgba(255, 255, 255, 0.10);
      --series-1: #3987e5;
      --series-2: #d95926;
      --series-3: #199e70;
      --seq-0: #fce8e8;
      --seq-1: #f5b5b5;
      --seq-2: #e87676;
      --seq-3: #cf3b3b;
      --seq-4: #8e1d1d;
      --good: #0ca30c;
      --bad: #e66767;
      --wash: rgba(255, 255, 255, 0.05);
      --band: rgba(137, 135, 129, 0.16);
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--page);
    color: var(--ink);
    font: 14px/1.55 system-ui, -apple-system, "Segoe UI", "Microsoft YaHei", sans-serif;
  }
  .wrap { max-width: 1180px; margin: 0 auto; padding: 28px 20px 56px; }
  header h1 { margin: 0 0 4px; font-size: 21px; font-weight: 650; letter-spacing: 0.01em; }
  .meta { color: var(--ink-2); font-size: 12.5px; }
  .meta span + span::before { content: " · "; color: var(--muted); }

  .filters {
    display: flex; flex-wrap: wrap; align-items: center; gap: 10px;
    margin: 22px 0 18px;
  }
  .pills { display: inline-flex; flex-wrap: wrap; gap: 4px; padding: 3px; background: var(--wash); border-radius: 9px; }
  .pill {
    appearance: none; border: 0; background: transparent; color: var(--ink-2);
    font: inherit; font-size: 13px; padding: 5px 12px; border-radius: 7px; cursor: pointer;
  }
  .pill:hover { background: var(--wash); color: var(--ink); }
  .pill[aria-pressed="true"] { background: var(--surface); color: var(--ink); box-shadow: 0 0 0 1px var(--border); font-weight: 600; }
  .range { margin-left: auto; display: flex; align-items: center; gap: 8px; color: var(--ink-2); font-size: 13px; }
  .range select {
    font: inherit; font-size: 13px; color: var(--ink); background: var(--surface);
    border: 1px solid var(--border); border-radius: 7px; padding: 5px 8px;
  }
  .control { display: flex; align-items: center; gap: 8px; color: var(--ink-2); font-size: 13px; }
  .control select {
    font: inherit; font-size: 13px; color: var(--ink); background: var(--surface);
    border: 1px solid var(--border); border-radius: 7px; padding: 5px 8px; max-width: 240px;
  }

  .kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 12px; }
  .tile {
    background: var(--surface); border: 1px solid var(--border); border-radius: 10px;
    padding: 14px 16px;
  }
  .tile .name { color: var(--ink-2); font-size: 12.5px; display: flex; align-items: center; gap: 7px; }
  .tile .value { font-size: 30px; font-weight: 620; margin-top: 2px; }
  .tile .value.empty { color: var(--muted); font-size: 20px; font-weight: 500; padding: 7px 0 3px; }
  .tile .delta { font-size: 12.5px; margin-left: 8px; font-weight: 600; }
  .tile .delta.up { color: var(--good); }
  .tile .delta.down { color: var(--bad); }
  .tile .sub { color: var(--muted); font-size: 12px; margin-top: 2px; }

  .card {
    background: var(--surface); border: 1px solid var(--border); border-radius: 10px;
    padding: 18px 20px 12px; margin-top: 14px;
  }
  .card-head { display: flex; flex-wrap: wrap; align-items: baseline; gap: 8px 18px; }
  .card h2 { font-size: 15px; font-weight: 620; margin: 0; }
  .card .hint { color: var(--muted); font-size: 12px; }
  .sub-title { font-size: 13px; font-weight: 600; margin: 14px 0 2px; color: var(--ink-2); }
  .legend { display: flex; flex-wrap: wrap; gap: 14px; margin: 8px 0 2px; color: var(--ink-2); font-size: 12.5px; }
  .legend .item { display: inline-flex; align-items: center; gap: 6px; }
  .swatch { width: 10px; height: 10px; border-radius: 2px; display: inline-block; flex: none; }
  .key-line { width: 16px; border-top: 2px solid; border-radius: 1px; display: inline-block; flex: none; }
  .key-line.dashed { border-top-style: dashed; }

  .chart-box { position: relative; }
  svg.chart { display: block; width: 100%; height: auto; }
  svg.chart:focus { outline: none; }
  svg.chart:focus-visible { outline: 2px solid var(--series-1); outline-offset: 2px; border-radius: 4px; }
  .empty-state { color: var(--muted); font-size: 13px; padding: 34px 0 26px; text-align: center; }

  #tooltip {
    position: fixed; z-index: 20; pointer-events: none; display: none;
    background: var(--surface); border: 1px solid var(--border); border-radius: 8px;
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.12);
    padding: 8px 10px; min-width: 168px; font-size: 12px;
  }
  #tooltip .tt-week { color: var(--ink-2); font-size: 12px; margin-bottom: 4px; }
  #tooltip .tt-row { display: flex; align-items: center; gap: 7px; padding: 1.5px 0; }
  #tooltip .tt-key { width: 12px; border-top: 2px solid; border-radius: 1px; flex: none; }
  #tooltip .tt-key.dashed { border-top-style: dashed; }
  #tooltip .tt-name { color: var(--ink-2); }
  #tooltip .tt-val { margin-left: auto; color: var(--ink); font-weight: 640; font-variant-numeric: tabular-nums; }

  details.table-view { margin-top: 6px; border-top: 1px solid var(--grid); }
  details.table-view summary {
    cursor: pointer; color: var(--ink-2); font-size: 12.5px; padding: 9px 0 7px;
    list-style: none; display: flex; align-items: center; gap: 6px;
  }
  details.table-view summary::-webkit-details-marker { display: none; }
  details.table-view summary::before { content: "▸"; color: var(--muted); transition: transform 0.15s; }
  details.table-view[open] summary::before { transform: rotate(90deg); }
  .table-scroll { overflow-x: auto; padding-bottom: 10px; }
  .table-note { color: var(--muted); font-size: 11.5px; margin: 0 0 10px; }
  .scale-legend { display: flex; align-items: center; gap: 8px; margin: 6px 0 8px; color: var(--muted); font-size: 11.5px; }
  .scale-bar { width: 140px; height: 8px; border-radius: 4px; display: inline-block; }
  table { border-collapse: collapse; width: 100%; font-size: 12.5px; }
  th, td { text-align: right; padding: 6px 10px; white-space: nowrap; }
  th { color: var(--muted); font-weight: 500; border-bottom: 1px solid var(--grid); }
  td { border-bottom: 1px solid var(--grid); font-variant-numeric: tabular-nums; }
  th:first-child, td:first-child { text-align: left; }
  tbody tr:hover td { background: var(--wash); }
  tfoot { color: var(--muted); font-size: 11.5px; }
  .note { color: var(--muted); font-size: 12px; margin-top: 18px; }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>Fundo 老客模型监控</h1>
    <div class="meta">
      <span id="meta-source"></span>
      <span id="meta-generated"></span>
      <span>周 = 放款周（dispersal_week，图中显示为该周周一日期），每申请取最新一次 run</span>
    </div>
  </header>

  <div class="filters" role="toolbar" aria-label="筛选">
    <div class="pills" id="label-pills" role="group" aria-label="标签"></div>
    <div class="pills" id="version-pills" role="group" aria-label="版本"></div>
    <label class="control">分箱模型
      <select id="bin-model-select"></select>
    </label>
    <label class="range">时间范围
      <select id="range-select">
        <option value="12">最近 12 周</option>
        <option value="26" selected>最近 26 周</option>
        <option value="52">最近 52 周</option>
        <option value="all">全部</option>
      </select>
    </label>
  </div>

  <section class="kpis" aria-label="最新一周概览"></section>

  <section class="card">
    <div class="card-head">
      <h2>周度 AUC</h2>
      <span class="hint">越高越好；阴影区 = 样本未成熟（已表现低于常规 75%），波动仅供参考</span>
    </div>
    <div class="legend" id="auc-legend"></div>
    <div class="chart-box">
      <svg class="chart" id="auc-chart" role="img" tabindex="0"></svg>
      <div class="empty-state" id="auc-empty" hidden>当前筛选下暂无可用的 AUC</div>
    </div>
    <details class="table-view">
      <summary>表格视图</summary>
      <div class="table-scroll" id="auc-table"></div>
    </details>
  </section>

  <section class="card">
    <div class="card-head">
      <h2>周度样本量</h2>
      <span class="hint">已表现样本 = 标签已成熟的申请；浅色柱 = 样本未成熟</span>
    </div>
    <div class="chart-box">
      <svg class="chart" id="count-chart" role="img" tabindex="0"></svg>
      <div class="empty-state" id="count-empty" hidden>当前筛选下暂无样本数据</div>
    </div>
  </section>

  <section class="card" id="funnel-card" hidden>
    <div class="card-head">
      <h2>转化率（按申请周 · 老客）</h2>
      <span class="hint">完成率 = 完成/申请；通过率 = 通过/完成；成交率 = 成交/通过；成交 = Active_Account / Closed / Blocked</span>
    </div>
    <div class="legend" id="funnel-legend"></div>
    <div class="chart-box">
      <svg class="chart" id="funnel-chart" role="img" tabindex="0"></svg>
      <div class="empty-state" id="funnel-empty" hidden>当前筛选下暂无转化数据</div>
    </div>
    <details class="table-view">
      <summary>表格视图</summary>
      <div class="table-scroll" id="funnel-table"></div>
    </details>
  </section>

  <section class="card" id="bin-card" hidden>
    <div class="card-head">
      <h2>分箱坏账率（按放款周）</h2>
      <span class="hint" id="bin-hint">行为箱 1-5，列为周（左旧右新）；颜色越深坏账率越高</span>
    </div>
    <h3 class="sub-title">FPD7</h3>
    <div class="scale-legend" id="bin-scale-fpd7"></div>
    <div class="chart-box">
      <svg class="chart" id="bin-chart-fpd7" role="img" tabindex="0"></svg>
      <div class="empty-state" id="bin-empty-fpd7" hidden>当前筛选下暂无分箱数据</div>
    </div>
    <details class="table-view">
      <summary>FPD7 表格视图</summary>
      <div class="table-scroll" id="bin-table-fpd7"></div>
    </details>
    <h3 class="sub-title">首期 30+</h3>
    <div class="scale-legend" id="bin-scale-1m30"></div>
    <div class="chart-box">
      <svg class="chart" id="bin-chart-1m30" role="img" tabindex="0"></svg>
      <div class="empty-state" id="bin-empty-1m30" hidden>当前筛选下暂无分箱数据</div>
    </div>
    <details class="table-view">
      <summary>首期 30+ 表格视图</summary>
      <div class="table-scroll" id="bin-table-1m30"></div>
    </details>
  </section>

  <section class="card" id="dist-card" hidden>
    <div class="card-head">
      <h2>模型分分布（按申请周 · 申请样本）</h2>
      <span class="hint">各分箱申请量占比；颜色越深 = 分箱越高（分数越差）</span>
    </div>
    <div class="legend" id="dist-legend"></div>
    <div class="chart-box">
      <svg class="chart" id="dist-chart" role="img" tabindex="0"></svg>
      <div class="empty-state" id="dist-empty" hidden>当前筛选下暂无分布数据</div>
    </div>
    <details class="table-view">
      <summary>表格视图</summary>
      <div class="table-scroll" id="dist-table"></div>
    </details>
  </section>

  <p class="note">
    模型说明：mltmodel = 融合主模型，submodel = 银行流水子模型，appmodel = 行为子模型。
    口径说明：标签取自 ba.customer_profile_rawdata（FPD7）与 model.tmp_eliam_listing_vintage（首期/2 期/3 期），
    未放款申请不参与 AUC；最近一周的 FPD7、近 1-3 个月的 30+ 标签尚未成熟，样本量会明显偏低属正常现象。
    v1.2 于 2026-09-23 上线，此前周的 v1.2 分为离线回填（回测口径）；submodel v1.2 在 2026Q1 前覆盖约 68%-81%。
  </p>
</div>

<div id="tooltip" role="status"></div>

<script>
const DATA = __DATA_JSON__;

const NS = 'http://www.w3.org/2000/svg';
const state = { label: DATA.labels.length ? DATA.labels[0].key : null, range: '26', version: 'compare', binModel: null };
const SVG_W = 960;
const AUC_H = 350;
const COUNT_H = 210;
const M = { top: 18, right: 16, bottom: 30, left: 56 };

const $ = (sel) => document.querySelector(sel);
const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
const fmtInt = new Intl.NumberFormat('zh-CN');
const fmtCompact = new Intl.NumberFormat('zh-CN', { notation: 'compact', maximumFractionDigits: 1 });
const fmtAuc = (v) => (v === null || v === undefined) ? '—' : v.toFixed(3);

function svgEl(tag, attrs = {}, parent) {
  const node = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
  if (parent) parent.appendChild(node);
  return node;
}

function cell(label, week, model) {
  const byWeek = (DATA.rows[label] || {})[week];
  return byWeek ? byWeek[model] : undefined;
}

function maturityOf(label, week) {
  const value = (DATA.maturity[label] || {})[week];
  return value === undefined ? null : value;
}

function isImmature(label, week) {
  const value = maturityOf(label, week);
  return value !== null && value < DATA.maturityThreshold;
}

function barOpacity(week) {
  return isImmature(state.label, week) ? 0.35 : 0.85;
}

function visibleWeeks() {
  if (state.range === 'all') return DATA.weeks.slice();
  return DATA.weeks.slice(-Number(state.range));
}

function familyList() {
  const families = [];
  DATA.models.forEach((model) => {
    if (!families.includes(model.name)) families.push(model.name);
  });
  return families;
}

function modelColor(family) {
  const index = familyList().indexOf(family);
  return cssVar('--series-' + Math.min(index + 1, 3));
}

function buildPayloadMaps() {
  return DATA.models.map((model) => ({
    ...model,
    color: modelColor(model.name),
    dashed: model.version === '1.2',
    display: model.version ? model.name + ' · ' + model.version : model.name,
  }));
}

function visibleModels() {
  const all = buildPayloadMaps();
  if (state.version === 'compare') return all;
  return all.filter((model) => model.version === state.version || model.version === '');
}

function renderPills() {
  const box = $('#label-pills');
  box.textContent = '';
  DATA.labels.forEach((label) => {
    const b = document.createElement('button');
    b.className = 'pill';
    b.textContent = label.name;
    b.setAttribute('aria-pressed', String(state.label === label.key));
    b.addEventListener('click', () => {
      state.label = label.key;
      renderPills();
      renderAll();
    });
    box.appendChild(b);
  });
}

const VERSION_VIEWS = [['1.1', '1.1'], ['1.2', '1.2'], ['compare', '对比']];

function renderVersionPills() {
  const box = $('#version-pills');
  box.textContent = '';
  VERSION_VIEWS.forEach(([key, name]) => {
    const b = document.createElement('button');
    b.className = 'pill';
    b.textContent = name;
    b.setAttribute('aria-pressed', String(state.version === key));
    b.addEventListener('click', () => {
      state.version = key;
      renderVersionPills();
      renderAll();
    });
    box.appendChild(b);
  });
}

function shortWeek(week) {
  let m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(week);
  if (m) return m[2] + '-' + m[3];
  m = /^(\d{4})-?(W\d+)$/i.exec(week);
  if (m) return m[2];
  return week;
}

function yearMonth(week) {
  let m = /^(\d{4})-(\d{2})/.exec(week);
  if (m) return m[1].slice(2) + '-' + m[2];
  m = /^(\d{4})-?W(\d{2})$/i.exec(week);
  if (m) return m[1].slice(2) + '-W' + m[2];
  return week;
}

function tickIndices(n, count) {
  if (n <= count) return Array.from({ length: n }, (_, i) => i);
  const step = (n - 1) / (count - 1);
  return Array.from({ length: count }, (_, i) => Math.round(i * step))
    .filter((v, i, arr) => arr.indexOf(v) === i);
}

function niceStep(span, target) {
  const raw = span / Math.max(target, 1);
  const mag = Math.pow(10, Math.floor(Math.log10(raw)));
  const norm = raw / mag;
  const step = norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 5 ? 5 : 10;
  return step * mag;
}

function latestPoint(label, weeks, model, field) {
  for (let i = weeks.length - 1; i >= 0; i--) {
    const c = cell(label, weeks[i], model);
    if (c && c[field] !== null && c[field] !== undefined) return { week: weeks[i], value: c[field], index: i };
  }
  return null;
}

function previousPoint(label, weeks, model, field, beforeIndex) {
  for (let i = beforeIndex - 1; i >= 0; i--) {
    const c = cell(label, weeks[i], model);
    if (c && c[field] !== null && c[field] !== undefined) return { week: weeks[i], value: c[field], index: i };
  }
  return null;
}

function renderKpis(weeks) {
  const box = $('.kpis');
  box.textContent = '';
  const all = buildPayloadMaps();
  const families = [];
  all.forEach((model) => {
    if (model.version && !families.some((f) => f.name === model.name)) {
      families.push({
        name: model.name,
        color: model.color,
        v11: all.find((m) => m.name === model.name && m.version === '1.1') || null,
        v12: all.find((m) => m.name === model.name && m.version === '1.2') || null,
      });
    }
  });
  const benchmark = all.find((model) => !model.version) || null;

  const tiles = families.map((family) => {
    const mainModel = state.version === '1.1'
      ? (family.v11 || family.v12)
      : (family.v12 || family.v11);
    if (!mainModel) {
      return { name: family.name, color: family.color, dashed: false, value: null, delta: null, sub: '暂无成熟样本' };
    }
    const latest = latestPoint(state.label, weeks, mainModel.key, 'auc');
    if (!latest) {
      return { name: family.name, color: family.color, dashed: false, value: null, delta: null, sub: '暂无成熟样本' };
    }
    const row = cell(state.label, latest.week, mainModel.key);
    const perf = row && row.perf != null ? row.perf : 0;
    const mature = !isImmature(state.label, latest.week);
    const subBase = (mature ? '' : '样本未成熟 · ') + `已表现 ${fmtInt.format(perf)} · ${latest.week}`;
    let delta = null;
    let sub = subBase;
    if (state.version === 'compare' && family.v11 && mainModel.key !== family.v11.key) {
      const other = cell(state.label, latest.week, family.v11.key);
      if (other && other.auc != null) {
        if (mature) delta = latest.value - other.auc;
        sub = `1.1 ${fmtAuc(other.auc)} · ${subBase}`;
      }
    } else if (mature) {
      const prev = previousPoint(state.label, weeks, mainModel.key, 'auc', latest.index);
      if (prev && !isImmature(state.label, prev.week)) delta = latest.value - prev.value;
    }
    return {
      name: state.version === 'compare' ? family.name : family.name + ' ' + mainModel.version,
      color: family.color,
      dashed: state.version === '1.2',
      value: fmtAuc(latest.value),
      delta,
      sub,
    };
  });

  if (benchmark) {
    const latest = latestPoint(state.label, weeks, benchmark.key, 'auc');
    const row = latest ? cell(state.label, latest.week, benchmark.key) : null;
    tiles.push({
      name: benchmark.name,
      color: benchmark.color,
      dashed: false,
      value: latest ? fmtAuc(latest.value) : null,
      delta: null,
      sub: latest
        ? `已表现 ${fmtInt.format(row && row.perf != null ? row.perf : 0)} · ${latest.week}`
        : '暂无成熟样本',
    });
  }

  const sampleModel = all.length ? all[0].key : '';
  const sampleLatest = latestPoint(state.label, weeks, sampleModel, 'perf');
  let sample = { name: '最新周申请量', color: null, dashed: false, value: null, sub: '暂无数据' };
  if (sampleLatest) {
    const row = cell(state.label, sampleLatest.week, sampleModel);
    sample = {
      name: '最新周申请量', color: null, dashed: false,
      value: fmtInt.format(row && row.total != null ? row.total : 0),
      sub: `已表现 ${fmtInt.format(row && row.perf != null ? row.perf : 0)} · 坏样本 ${fmtInt.format(row && row.pos != null ? row.pos : 0)} · ${sampleLatest.week}`,
    };
  }
  tiles.push(sample);

  tiles.forEach((tile) => {
    const el = document.createElement('div');
    el.className = 'tile';
    const name = document.createElement('div');
    name.className = 'name';
    if (tile.color) {
      const key = document.createElement('span');
      key.className = 'key-line' + (tile.dashed ? ' dashed' : '');
      key.style.borderTopColor = tile.color;
      name.appendChild(key);
    }
    name.appendChild(document.createTextNode(tile.name));
    el.appendChild(name);

    const value = document.createElement('div');
    value.className = 'value' + (tile.value === null ? ' empty' : '');
    value.textContent = tile.value === null ? '暂无数据' : tile.value;
    if (tile.delta !== null && tile.delta !== undefined) {
      const d = document.createElement('span');
      d.className = 'delta ' + (tile.delta >= 0 ? 'up' : 'down');
      d.textContent = (tile.delta >= 0 ? '+' : '') + tile.delta.toFixed(3);
      value.appendChild(d);
    }
    el.appendChild(value);

    const sub = document.createElement('div');
    sub.className = 'sub';
    sub.textContent = tile.sub;
    el.appendChild(sub);
    box.appendChild(el);
  });
}

function renderLegend() {
  const box = $('#auc-legend');
  box.textContent = '';
  visibleModels().forEach((model) => {
    const item = document.createElement('span');
    item.className = 'item';
    const key = document.createElement('span');
    key.className = 'key-line' + (model.dashed ? ' dashed' : '');
    key.style.borderTopColor = model.color;
    item.appendChild(key);
    item.appendChild(document.createTextNode(model.display));
    box.appendChild(item);
  });
}

let tooltip = null;
function ensureTooltip() {
  if (!tooltip) tooltip = $('#tooltip');
  return tooltip;
}
function hideTooltip() { ensureTooltip().style.display = 'none'; }
function showTooltip(build, clientX, clientY) {
  const tip = ensureTooltip();
  tip.textContent = '';
  build(tip);
  tip.style.display = 'block';
  const pad = 14;
  const rect = tip.getBoundingClientRect();
  let x = clientX + pad;
  let y = clientY - rect.height - pad;
  if (x + rect.width > window.innerWidth - 8) x = clientX - rect.width - pad;
  if (y < 8) y = clientY + pad;
  tip.style.left = x + 'px';
  tip.style.top = y + 'px';
}

function addTooltipRow(tip, color, name, value, dashed = false) {
  const row = document.createElement('div');
  row.className = 'tt-row';
  if (color) {
    const key = document.createElement('span');
    key.className = 'tt-key' + (dashed ? ' dashed' : '');
    key.style.borderTopColor = color;
    row.appendChild(key);
  }
  const label = document.createElement('span');
  label.className = 'tt-name';
  label.textContent = name;
  row.appendChild(label);
  const val = document.createElement('span');
  val.className = 'tt-val';
  val.textContent = value;
  row.appendChild(val);
  tip.appendChild(row);
}

function attachCrosshair(svg, viewW, plotLeft, plotWidth, weeks, handlers) {
  const overlay = svgEl('rect', {
    x: plotLeft, y: 0, width: plotWidth, height: 1, fill: 'transparent',
  }, svg);
  overlay.setAttribute('height', '100%');

  const moveTo = (index, clientX, clientY) => {
    if (index < 0 || index >= weeks.length) return;
    handlers.show(index, clientX, clientY);
  };

  let keyboardIndex = weeks.length - 1;
  overlay.addEventListener('pointermove', (event) => {
    const rect = svg.getBoundingClientRect();
    const x = (event.clientX - rect.left) * viewW / rect.width;
    const ratio = Math.min(Math.max((x - plotLeft) / plotWidth, 0), 0.999999);
    keyboardIndex = Math.floor(ratio * weeks.length);
    moveTo(keyboardIndex, event.clientX, event.clientY);
  });
  overlay.addEventListener('pointerleave', () => handlers.hide());
  svg.addEventListener('blur', () => handlers.hide());
  svg.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
      event.preventDefault();
      keyboardIndex = Math.min(Math.max(keyboardIndex + (event.key === 'ArrowRight' ? 1 : -1), 0), weeks.length - 1);
      const node = handlers.showAt ? handlers.showAt(keyboardIndex) : null;
      handlers.show(keyboardIndex, node ? node.x : window.innerWidth / 2, node ? node.y : window.innerHeight / 2);
    } else if (event.key === 'Escape') {
      handlers.hide();
    }
  });
  svg.addEventListener('focus', () => {
    if (!weeks.length) return;
    keyboardIndex = Math.min(keyboardIndex, weeks.length - 1);
    const node = handlers.showAt ? handlers.showAt(keyboardIndex) : null;
    handlers.show(keyboardIndex, node ? node.x : window.innerWidth / 2, node ? node.y : window.innerHeight / 2);
  });
}

function clearSvg(svg) {
  while (svg.firstChild) svg.removeChild(svg.firstChild);
}

function drawYAxis(svg, plot, ticks, formatter, x0) {
  const axis = cssVar('--axis');
  ticks.forEach((t) => {
    const y = plot.y(t.value);
    svgEl('line', {
      x1: plot.left, x2: plot.left + plot.width, y1: y, y2: y,
      stroke: cssVar('--grid'), 'stroke-width': 1,
    }, svg);
    const label = svgEl('text', {
      x: plot.left - 10, y: y + 4, 'text-anchor': 'end',
      'font-size': 11, fill: cssVar('--muted'),
      'font-variant-numeric': 'tabular-nums',
    }, svg);
    label.textContent = formatter(t.value);
  });
  svgEl('line', {
    x1: plot.left, x2: plot.left + plot.width, y1: plot.y(ticks[ticks.length - 1].value),
    y2: plot.y(ticks[ticks.length - 1].value), stroke: axis, 'stroke-width': 1,
  }, svg);
}

function drawXAxis(svg, plot, weeks, xOf, height) {
  const indices = tickIndices(weeks.length, 8);
  const longSpan = weeks.length > 52;
  const y = height - M.bottom + 18;
  indices.forEach((i) => {
    const t = svgEl('text', {
      x: xOf(i), y, 'text-anchor': 'middle',
      'font-size': 11, fill: cssVar('--muted'),
    }, svg);
    t.textContent = longSpan ? yearMonth(weeks[i]) : shortWeek(weeks[i]);
  });
}

function renderAucChart(weeks) {
  const svg = $('#auc-chart');
  const empty = $('#auc-empty');
  clearSvg(svg);
  svg.setAttribute('viewBox', `0 0 ${SVG_W} ${AUC_H}`);

  const models = visibleModels();
  const values = [];
  weeks.forEach((week) => {
    models.forEach((model) => {
      const c = cell(state.label, week, model.key);
      if (c && c.auc !== null && c.auc !== undefined) values.push(c.auc);
    });
  });
  if (!values.length || !weeks.length) {
    svg.style.display = 'none';
    empty.hidden = false;
    return;
  }
  svg.style.display = 'block';
  empty.hidden = true;

  const yMin = 0;
  const yMax = 1;

  const plot = { left: M.left, top: M.top, width: SVG_W - M.left - M.right, height: AUC_H - M.top - M.bottom };
  plot.y = (v) => plot.top + (yMax - v) / (yMax - yMin) * plot.height;
  const xOf = (i) => plot.left + (i + 0.5) * plot.width / weeks.length;

  const step = niceStep(yMax - yMin, 5);
  const start = Math.ceil(yMin / step) * step;
  const ticks = [];
  for (let v = start; v <= yMax + 1e-9; v += step) ticks.push({ value: Number(v.toFixed(4)) });
  drawYAxis(svg, plot, ticks, (v) => v === 0 ? '0' : v.toFixed(1));
  drawXAxis(svg, plot, weeks, xOf, AUC_H);

  // 样本未成熟周打底纹，提示该段 AUC 波动不可靠
  const bandWidth = plot.width / weeks.length;
  weeks.forEach((week, i) => {
    if (!isImmature(state.label, week)) return;
    svgEl('rect', {
      x: plot.left + i * bandWidth, y: plot.top,
      width: bandWidth, height: plot.height, fill: cssVar('--band'),
    }, svg);
  });

  const series = models.map((model) => {
    const points = weeks.map((week, i) => {
      const c = cell(state.label, week, model.key);
      return c && c.auc !== null && c.auc !== undefined ? { i, v: c.auc } : null;
    });
    return { model, points };
  });

  series.forEach(({ model, points }) => {
    let d = '';
    let open = false;
    points.forEach((p) => {
      if (!p) { open = false; return; }
      d += (open ? 'L' : 'M') + xOf(p.i) + ',' + plot.y(p.v) + ' ';
      open = true;
    });
    if (d) {
      const attrs = {
        d,
        fill: 'none', stroke: model.color, 'stroke-width': 2,
        'stroke-linejoin': 'round', 'stroke-linecap': 'round',
      };
      if (model.dashed) attrs['stroke-dasharray'] = '6 4';
      svgEl('path', attrs, svg);
    }
  });

  // 末端标记 + 直接标签（避免互相重叠时只靠图例）
  const ends = series.map(({ model, points }) => {
    const last = points.filter(Boolean).pop();
    return last ? { model, x: xOf(last.i), y: plot.y(last.v), v: last.v } : null;
  }).filter(Boolean);
  ends.sort((a, b) => a.y - b.y);
  const spaced = ends.every((e, i) => i === 0 || e.y - ends[i - 1].y >= 13);
  ends.forEach((e) => {
    svgEl('circle', {
      cx: e.x, cy: e.y, r: 4, fill: e.model.color,
      stroke: cssVar('--surface'), 'stroke-width': 2,
    }, svg);
    if (spaced) {
      const label = svgEl('text', {
        x: Math.min(e.x + 9, SVG_W - 4), y: e.y + 4,
        'font-size': 11, fill: cssVar('--ink-2'),
        'font-variant-numeric': 'tabular-nums',
      }, svg);
      label.textContent = e.v.toFixed(3);
    }
  });

  const crosshair = svgEl('line', {
    y1: plot.top, y2: plot.top + plot.height, stroke: cssVar('--axis'),
    'stroke-width': 1, visibility: 'hidden',
  }, svg);

  attachCrosshair(svg, SVG_W, plot.left, plot.width, weeks, {
    show(index, clientX, clientY) {
      const x = xOf(index);
      crosshair.setAttribute('x1', x);
      crosshair.setAttribute('x2', x);
      crosshair.setAttribute('visibility', 'visible');
      showTooltip((tip) => {
        const head = document.createElement('div');
        head.className = 'tt-week';
        head.textContent = weeks[index];
        tip.appendChild(head);
        models.forEach((model) => {
          const c = cell(state.label, weeks[index], model.key);
          addTooltipRow(tip, model.color, model.display, c ? fmtAuc(c.auc) : '—', model.dashed);
        });
        let perf = null;
        models.forEach((model) => {
          const c = cell(state.label, weeks[index], model.key);
          if (c && c.perf !== undefined && c.perf !== null) perf = c.perf;
        });
        if (perf !== null) addTooltipRow(tip, null, '已表现样本', fmtInt.format(perf));
        const mat = maturityOf(state.label, weeks[index]);
        if (mat !== null) {
          addTooltipRow(tip, null, '成熟度', Math.round(mat * 100) + '%' + (mat < DATA.maturityThreshold ? '（未成熟）' : ''));
        }
      }, clientX, clientY);
    },
    showAt(index) {
      const svgRect = svg.getBoundingClientRect();
      const scale = svgRect.width / SVG_W;
      const plotMidY = plot.top + plot.height / 2 + svgRect.top;
      return { x: svgRect.left + xOf(index) * scale, y: plotMidY };
    },
    hide() {
      crosshair.setAttribute('visibility', 'hidden');
      hideTooltip();
    },
  });
}

function renderCountChart(weeks) {
  const svg = $('#count-chart');
  const empty = $('#count-empty');
  clearSvg(svg);
  svg.setAttribute('viewBox', `0 0 ${SVG_W} ${COUNT_H}`);

  const models = buildPayloadMaps();
  const perfByWeek = weeks.map((week) => {
    for (const model of models) {
      const c = cell(state.label, week, model.key);
      if (c && c.perf !== null && c.perf !== undefined) return c.perf;
    }
    return 0;
  });
  if (!weeks.length || perfByWeek.every((v) => v === 0)) {
    svg.style.display = 'none';
    empty.hidden = false;
    return;
  }
  svg.style.display = 'block';
  empty.hidden = true;

  const plot = { left: M.left, top: M.top, width: SVG_W - M.left - M.right, height: COUNT_H - M.top - M.bottom };
  const yMax = Math.max(...perfByWeek);
  const step = niceStep(yMax, 4);
  const top = Math.ceil(yMax / step) * step;
  plot.y = (v) => plot.top + (1 - v / top) * plot.height;
  const band = plot.width / weeks.length;
  const barW = Math.min(24, band * 0.62);
  const xOf = (i) => plot.left + (i + 0.5) * band;

  const ticks = [];
  for (let v = 0; v <= top + 1e-9; v += step) ticks.push({ value: v });
  drawYAxis(svg, plot, ticks, (v) => v === 0 ? '0' : fmtCompact.format(v));
  drawXAxis(svg, plot, weeks, xOf, COUNT_H);

  const bars = [];
  weeks.forEach((week, i) => {
    const value = perfByWeek[i];
    if (!value) return;
    const x = xOf(i) - barW / 2;
    const y = plot.y(value);
    const h = plot.top + plot.height - y;
    const r = Math.min(4, h, barW / 2);
    const d = `M${x},${y + h} L${x},${y + r} Q${x},${y} ${x + r},${y} L${x + barW - r},${y} Q${x + barW},${y} ${x + barW},${y + r} L${x + barW},${y + h} Z`;
    const bar = svgEl('path', {
      d, fill: cssVar('--series-1'), 'fill-opacity': barOpacity(week),
    }, svg);
    bars.push({ week, value, node: bar });
  });

  const crosshair = svgEl('line', {
    y1: plot.top, y2: plot.top + plot.height, stroke: cssVar('--axis'),
    'stroke-width': 1, visibility: 'hidden',
  }, svg);

  attachCrosshair(svg, SVG_W, plot.left, plot.width, weeks, {
    show(index, clientX, clientY) {
      bars.forEach((b) => b.node.setAttribute('fill-opacity', barOpacity(b.week)));
      const mine = bars.find((b) => b.week === weeks[index]);
      if (mine) mine.node.setAttribute('fill-opacity', 1);
      const x = xOf(index);
      crosshair.setAttribute('x1', x);
      crosshair.setAttribute('x2', x);
      crosshair.setAttribute('visibility', 'visible');
      showTooltip((tip) => {
        const head = document.createElement('div');
        head.className = 'tt-week';
        head.textContent = weeks[index];
        tip.appendChild(head);
        let row = null;
        for (const model of models) {
          const c = cell(state.label, weeks[index], model.key);
          if (c) { row = c; break; }
        }
        if (row) {
          addTooltipRow(tip, null, '申请量', fmtInt.format(row.total != null ? row.total : 0));
          addTooltipRow(tip, null, '已表现', fmtInt.format(row.perf != null ? row.perf : 0));
          addTooltipRow(tip, null, '坏样本', fmtInt.format(row.pos != null ? row.pos : 0));
          const rate = row.perf ? (row.pos / row.perf * 100) : null;
          if (rate !== null) addTooltipRow(tip, null, '坏率', rate.toFixed(1) + '%');
        } else {
          addTooltipRow(tip, null, '样本', '—');
        }
      }, clientX, clientY);
    },
    showAt(index) {
      const svgRect = svg.getBoundingClientRect();
      const scale = svgRect.width / SVG_W;
      return {
        x: svgRect.left + xOf(index) * scale,
        y: svgRect.top + plot.top + plot.height / 2,
      };
    },
    hide() {
      bars.forEach((b) => b.node.setAttribute('fill-opacity', barOpacity(b.week)));
      crosshair.setAttribute('visibility', 'hidden');
      hideTooltip();
    },
  });
}

function renderTable(weeks) {
  const box = $('#auc-table');
  box.textContent = '';
  const models = visibleModels();
  const table = document.createElement('table');

  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  ['周'].forEach((t) => { const th = document.createElement('th'); th.textContent = t; headRow.appendChild(th); });
  models.forEach((model) => { const th = document.createElement('th'); th.textContent = model.display; headRow.appendChild(th); });
  ['已表现', '成熟度', '坏样本', '坏率'].forEach((t) => { const th = document.createElement('th'); th.textContent = t; headRow.appendChild(th); });
  thead.appendChild(headRow);
  table.appendChild(thead);

  const tbody = document.createElement('tbody');
  weeks.slice().reverse().forEach((week) => {
    const tr = document.createElement('tr');
    const th = document.createElement('td');
    th.textContent = week;
    tr.appendChild(th);
    let perf = null, pos = null;
    models.forEach((model) => {
      const c = cell(state.label, week, model.key);
      const td = document.createElement('td');
      td.textContent = c ? fmtAuc(c.auc) : '—';
      tr.appendChild(td);
      if (c) {
        if (perf === null && c.perf !== null && c.perf !== undefined) perf = c.perf;
        if (pos === null && c.pos !== null && c.pos !== undefined) pos = c.pos;
      }
    });
    const tdPerf = document.createElement('td');
    tdPerf.textContent = perf === null ? '—' : fmtInt.format(perf);
    tr.appendChild(tdPerf);
    const mat = maturityOf(state.label, week);
    const tdMat = document.createElement('td');
    tdMat.textContent = mat === null
      ? '—'
      : Math.round(mat * 100) + '%' + (mat < DATA.maturityThreshold ? '*' : '');
    tr.appendChild(tdMat);
    const tdPos = document.createElement('td');
    tdPos.textContent = pos === null ? '—' : fmtInt.format(pos);
    tr.appendChild(tdPos);
    const tdRate = document.createElement('td');
    tdRate.textContent = (perf && pos !== null) ? (pos / perf * 100).toFixed(1) + '%' : '—';
    tr.appendChild(tdRate);
    tbody.appendChild(tr);
  });
  table.appendChild(tbody);
  box.appendChild(table);
  if (weeks.some((week) => isImmature(state.label, week))) {
    const note = document.createElement('p');
    note.className = 'table-note';
    note.textContent = '* 样本未成熟（已表现低于常规水平的 '
      + Math.round(DATA.maturityThreshold * 100) + '%），AUC 波动较大，仅供参考';
    box.appendChild(note);
  }
}

const FUNNEL_SERIES = [
  { key: 'completion', name: '完成率', colorVar: '--series-1' },
  { key: 'approval', name: '通过率', colorVar: '--series-2' },
  { key: 'deal', name: '成交率', colorVar: '--series-3' },
];

function funnelRow(week) {
  return (DATA.funnel && DATA.funnel.rows[week]) || null;
}

function rateOf(num, den) {
  return (num === null || num === undefined || den === null || den === undefined || !den)
    ? null : num / den;
}

function funnelRates(row) {
  if (!row) return null;
  return {
    completion: rateOf(row.completed, row.apply),
    approval: rateOf(row.approved, row.completed),
    deal: rateOf(row.deal, row.approved),
  };
}

function visibleFunnelWeeks() {
  if (!DATA.funnel) return [];
  return state.range === 'all'
    ? DATA.funnel.weeks.slice()
    : DATA.funnel.weeks.slice(-Number(state.range));
}

function renderFunnel() {
  const card = $('#funnel-card');
  if (!DATA.funnel || !DATA.funnel.weeks.length) {
    card.hidden = true;
    return;
  }
  card.hidden = false;
  const weeks = visibleFunnelWeeks();
  renderFunnelLegend();
  renderFunnelChart(weeks);
  renderFunnelTable(weeks);
}

function renderFunnelLegend() {
  const box = $('#funnel-legend');
  box.textContent = '';
  FUNNEL_SERIES.forEach((series) => {
    const item = document.createElement('span');
    item.className = 'item';
    const key = document.createElement('span');
    key.className = 'key-line';
    key.style.borderTopColor = cssVar(series.colorVar);
    item.appendChild(key);
    item.appendChild(document.createTextNode(series.name));
    box.appendChild(item);
  });
}

function renderFunnelChart(weeks) {
  const svg = $('#funnel-chart');
  const empty = $('#funnel-empty');
  clearSvg(svg);
  svg.setAttribute('viewBox', `0 0 ${SVG_W} ${AUC_H}`);

  const series = FUNNEL_SERIES.map((item) => ({
    ...item,
    color: cssVar(item.colorVar),
    points: weeks.map((week, i) => {
      const rates = funnelRates(funnelRow(week));
      return rates && rates[item.key] !== null ? { i, v: rates[item.key] } : null;
    }),
  }));
  const hasData = series.some((item) => item.points.some(Boolean));
  if (!weeks.length || !hasData) {
    svg.style.display = 'none';
    empty.hidden = false;
    return;
  }
  svg.style.display = 'block';
  empty.hidden = true;

  const yMin = 0;
  const yMax = 1;
  const plot = { left: M.left, top: M.top, width: SVG_W - M.left - M.right, height: AUC_H - M.top - M.bottom };
  plot.y = (v) => plot.top + (yMax - v) / (yMax - yMin) * plot.height;
  const xOf = (i) => plot.left + (i + 0.5) * plot.width / weeks.length;

  const ticks = [0, 0.25, 0.5, 0.75, 1].map((v) => ({ value: v }));
  drawYAxis(svg, plot, ticks, (v) => Math.round(v * 100) + '%');
  drawXAxis(svg, plot, weeks, xOf, AUC_H);

  series.forEach((item) => {
    let d = '';
    let open = false;
    item.points.forEach((p) => {
      if (!p) { open = false; return; }
      d += (open ? 'L' : 'M') + xOf(p.i) + ',' + plot.y(p.v) + ' ';
      open = true;
    });
    if (d) {
      svgEl('path', {
        d, fill: 'none', stroke: item.color, 'stroke-width': 2,
        'stroke-linejoin': 'round', 'stroke-linecap': 'round',
      }, svg);
    }
  });

  series.forEach((item) => {
    const last = item.points.filter(Boolean).pop();
    if (!last) return;
    svgEl('circle', {
      cx: xOf(last.i), cy: plot.y(last.v), r: 4, fill: item.color,
      stroke: cssVar('--surface'), 'stroke-width': 2,
    }, svg);
  });

  const crosshair = svgEl('line', {
    y1: plot.top, y2: plot.top + plot.height, stroke: cssVar('--axis'),
    'stroke-width': 1, visibility: 'hidden',
  }, svg);

  const pct = (v) => (v === null ? '—' : (v * 100).toFixed(1) + '%');
  attachCrosshair(svg, SVG_W, plot.left, plot.width, weeks, {
    show(index, clientX, clientY) {
      const x = xOf(index);
      crosshair.setAttribute('x1', x);
      crosshair.setAttribute('x2', x);
      crosshair.setAttribute('visibility', 'visible');
      showTooltip((tip) => {
        const head = document.createElement('div');
        head.className = 'tt-week';
        head.textContent = weeks[index];
        tip.appendChild(head);
        const row = funnelRow(weeks[index]);
        const rates = funnelRates(row);
        FUNNEL_SERIES.forEach((item) => {
          addTooltipRow(tip, cssVar(item.colorVar), item.name, pct(rates ? rates[item.key] : null));
        });
        if (row) {
          addTooltipRow(tip, null, '申请量', fmtInt.format(row.apply != null ? row.apply : 0));
          addTooltipRow(tip, null, '完成/通过/成交',
            `${fmtInt.format(row.completed || 0)} / ${fmtInt.format(row.approved || 0)} / ${fmtInt.format(row.deal || 0)}`);
        }
      }, clientX, clientY);
    },
    showAt(index) {
      const svgRect = svg.getBoundingClientRect();
      const scale = svgRect.width / SVG_W;
      return { x: svgRect.left + xOf(index) * scale, y: svgRect.top + plot.top + plot.height / 2 };
    },
    hide() {
      crosshair.setAttribute('visibility', 'hidden');
      hideTooltip();
    },
  });
}

function renderFunnelTable(weeks) {
  const box = $('#funnel-table');
  box.textContent = '';
  const table = document.createElement('table');
  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  ['周', '申请量', '完成', '通过', '成交', '完成率', '通过率', '成交率', '自动占比'].forEach((text) => {
    const th = document.createElement('th');
    th.textContent = text;
    headRow.appendChild(th);
  });
  thead.appendChild(headRow);
  table.appendChild(thead);

  const tbody = document.createElement('tbody');
  weeks.slice().reverse().forEach((week) => {
    const row = funnelRow(week);
    const rates = funnelRates(row);
    const percent = (value) => (value === null || value === undefined) ? '—' : (value * 100).toFixed(1) + '%';
    const cells = [
      week,
      row && row.apply != null ? fmtInt.format(row.apply) : '—',
      row && row.completed != null ? fmtInt.format(row.completed) : '—',
      row && row.approved != null ? fmtInt.format(row.approved) : '—',
      row && row.deal != null ? fmtInt.format(row.deal) : '—',
      percent(rates ? rates.completion : null),
      percent(rates ? rates.approval : null),
      percent(rates ? rates.deal : null),
      row && row.auto != null && row.approved ? (row.auto / row.approved * 100).toFixed(1) + '%' : '—',
    ];
    const tr = document.createElement('tr');
    cells.forEach((text) => {
      const td = document.createElement('td');
      td.textContent = text;
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  });
  table.appendChild(tbody);
  box.appendChild(table);
}

function binPoint(label, week, model, bin) {
  const byWeek = ((DATA.bins && DATA.bins.rows[label]) || {})[week];
  const byModel = byWeek ? byWeek[model] : undefined;
  return byModel ? byModel[String(bin)] : undefined;
}

function visibleBinWeeks() {
  if (!DATA.bins) return [];
  return state.range === 'all'
    ? DATA.bins.weeks.slice()
    : DATA.bins.weeks.slice(-Number(state.range));
}

function binIntervalText(model, bin) {
  const limits = ((DATA.bins && DATA.bins.thresholds) || {})[model];
  if (!limits || limits.length !== 4) return '';
  const fmt = (value) => value.toFixed(4);
  if (bin === 1) return '≤' + fmt(limits[0]);
  if (bin === 5) return '>' + fmt(limits[3]);
  return fmt(limits[bin - 2]) + '~' + fmt(limits[bin - 1]);
}

function binModelsForVersion() {
  const all = buildPayloadMaps();
  if (state.version === 'compare') return all;
  return all.filter((model) => model.version === state.version);
}

function renderBinModelOptions() {
  const select = $('#bin-model-select');
  const models = binModelsForVersion();
  select.textContent = '';
  models.forEach((model) => {
    const option = document.createElement('option');
    option.value = model.key;
    option.textContent = model.display;
    select.appendChild(option);
  });
  if (!models.length) return;
  const keys = models.map((model) => model.key);
  if (!state.binModel || keys.indexOf(state.binModel) < 0) {
    const preferred = models.find((model) => model.version === '1.2' && model.name.indexOf('mltmodel') === 0)
      || models.find((model) => model.name.indexOf('mltmodel') === 0)
      || models[0];
    state.binModel = preferred.key;
  }
  select.value = state.binModel;
}

function renderBins() {
  const card = $('#bin-card');
  if (!DATA.bins || !DATA.bins.weeks.length) {
    card.hidden = true;
    return;
  }
  card.hidden = false;
  const limits = ((DATA.bins.thresholds) || {})[state.binModel];
  $('#bin-hint').textContent = (limits && limits.length === 4
    ? '箱 1-4 上限：' + limits.map((value) => value.toFixed(4)).join(' / ') + '；箱 5 为以上。'
    : '') + '行为箱 1-5，列为周（左旧右新）；颜色越深坏账率越高';
  renderBinHeatmap('fpd7_flag', 'fpd7');
  renderBinHeatmap('duedate_1m_30', '1m30');
}

const SEQ_STOPS = ['--seq-0', '--seq-1', '--seq-2', '--seq-3', '--seq-4'];

function hexToRgb(hex) {
  const value = hex.replace('#', '');
  const full = value.length === 3 ? value.split('').map((c) => c + c).join('') : value;
  return [parseInt(full.slice(0, 2), 16), parseInt(full.slice(2, 4), 16), parseInt(full.slice(4, 6), 16)];
}

function seqFill(t) {
  const stops = SEQ_STOPS.map((name) => hexToRgb(cssVar(name)));
  const pos = Math.min(Math.max(t, 0), 0.9999) * (stops.length - 1);
  const index = Math.min(Math.floor(pos), stops.length - 2);
  const f = pos - index;
  const mix = (i) => Math.round(stops[index][i] + (stops[index + 1][i] - stops[index][i]) * f);
  return 'rgb(' + mix(0) + ',' + mix(1) + ',' + mix(2) + ')';
}

function textOnFill(fill) {
  const match = /rgb\((\d+),(\d+),(\d+)\)/.exec(fill);
  if (!match) return '#0b0b0b';
  const channel = (value) => {
    const c = Number(value) / 255;
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  };
  const lum = 0.2126 * channel(match[1]) + 0.7152 * channel(match[2]) + 0.0722 * channel(match[3]);
  return lum > 0.45 ? '#0b0b0b' : '#ffffff';
}

function showCellTip(clientX, clientY, week, bin, rate, perf, modelName, fill) {
  showTooltip((tip) => {
    const head = document.createElement('div');
    head.className = 'tt-week';
    head.textContent = week + (modelName ? ' · ' + modelName : '');
    tip.appendChild(head);
    const interval = binIntervalText(state.binModel, bin);
    addTooltipRow(
      tip,
      fill,
      '箱 ' + bin + (interval ? ' (' + interval + ')' : ''),
      (rate * 100).toFixed(1) + '% · n ' + fmtInt.format(perf)
    );
  }, clientX, clientY);
}

function renderBinHeatmap(label, suffix) {
  const svg = $('#bin-chart-' + suffix);
  const empty = $('#bin-empty-' + suffix);
  const scaleBox = $('#bin-scale-' + suffix);
  clearSvg(svg);
  scaleBox.textContent = '';

  const allWeeks = visibleBinWeeks();
  const weeks = allWeeks;
  const model = state.binModel;
  const modelMeta = buildPayloadMaps().find((item) => item.key === model);
  const modelName = modelMeta ? modelMeta.display : (model || '');

  let maxRate = 0;
  weeks.forEach((week) => {
    for (let bin = 1; bin <= 5; bin++) {
      const point = binPoint(label, week, model, bin);
      if (point && point.perf) maxRate = Math.max(maxRate, point.pos / point.perf);
    }
  });
  if (!weeks.length || !maxRate) {
    svg.style.display = 'none';
    empty.hidden = false;
    renderBinTable(label, suffix, allWeeks, model);
    return;
  }
  svg.style.display = 'block';
  empty.hidden = true;

  const step = niceStep(Math.max(maxRate, 0.02), 4);
  const top = Math.ceil(maxRate / step) * step;
  const plot = { left: M.left, top: M.top, width: SVG_W - M.left - M.right };
  const cellW = plot.width / weeks.length;
  const cellH = Math.min(40, Math.max(24, Math.floor(cellW)));
  const height = plot.top + 5 * cellH + 30;
  svg.setAttribute('viewBox', `0 0 ${SVG_W} ${height}`);

  // 热力图统一用浅色底版，保证「风险越高颜色越深」在明暗主题下都成立
  svgEl('rect', {
    x: plot.left, y: plot.top, width: plot.width, height: 5 * cellH,
    fill: '#fcfcfb', rx: 3,
  }, svg);

  const xOf = (i) => plot.left + (i + 0.5) * cellW;

  for (let bin = 1; bin <= 5; bin++) {
    const text = svgEl('text', {
      x: plot.left - 8, y: plot.top + (bin - 0.5) * cellH + 3.5,
      'text-anchor': 'end', 'font-size': 10.5, fill: cssVar('--muted'),
    }, svg);
    text.textContent = '箱 ' + bin;
  }

  drawXAxis(svg, plot, weeks, xOf, height);

  const outline = svgEl('rect', {
    fill: 'none', stroke: '#0b0b0b', 'stroke-width': 2, visibility: 'hidden',
    'pointer-events': 'none',
  }, svg);

  weeks.forEach((week, col) => {
    for (let bin = 1; bin <= 5; bin++) {
      const point = binPoint(label, week, model, bin);
      if (!point || !point.perf) continue;
      const rate = point.pos / point.perf;
      const fill = seqFill(rate / top);
      const x = plot.left + col * cellW;
      const y = plot.top + (bin - 1) * cellH;
      const rect = svgEl('rect', {
        x: x + 1, y: y + 1, width: cellW - 2, height: cellH - 2, fill,
      }, svg);
      if (cellW >= 30) {
        const text = svgEl('text', {
          x: x + cellW / 2, y: y + cellH / 2 + 3.5,
          'text-anchor': 'middle', 'font-size': 10,
          fill: textOnFill(fill), 'font-variant-numeric': 'tabular-nums',
          'pointer-events': 'none',
        }, svg);
        text.textContent = (rate * 100).toFixed(1) + '%';
      } else if (cellW >= 16) {
        const text = svgEl('text', {
          x: x + cellW / 2, y: y + cellH / 2 + 3.5,
          'text-anchor': 'middle', 'font-size': 9,
          fill: textOnFill(fill), 'font-variant-numeric': 'tabular-nums',
          'pointer-events': 'none',
        }, svg);
        text.textContent = Math.round(rate * 100) + '%';
      }
      const highlight = () => {
        outline.setAttribute('x', x + 1);
        outline.setAttribute('y', y + 1);
        outline.setAttribute('width', cellW - 2);
        outline.setAttribute('height', cellH - 2);
        outline.setAttribute('visibility', 'visible');
      };
      rect.addEventListener('pointermove', (event) => {
        highlight();
        showCellTip(event.clientX, event.clientY, week, bin, rate, point.perf, modelName, fill);
      });
      rect.addEventListener('pointerleave', () => {
        outline.setAttribute('visibility', 'hidden');
        hideTooltip();
      });
    }
  });

  let activeRow = 0;
  let activeCol = weeks.length - 1;
  const paintActive = (showTip) => {
    const x = plot.left + activeCol * cellW;
    const y = plot.top + activeRow * cellH;
    outline.setAttribute('x', x + 1);
    outline.setAttribute('y', y + 1);
    outline.setAttribute('width', cellW - 2);
    outline.setAttribute('height', cellH - 2);
    outline.setAttribute('visibility', 'visible');
    const week = weeks[activeCol];
    const bin = activeRow + 1;
    const point = binPoint(label, week, model, bin);
    if (point && point.perf && showTip) {
      const rect = svg.getBoundingClientRect();
      const scale = rect.width / SVG_W;
      const cx = rect.left + (x + cellW / 2) * scale;
      const cy = rect.top + (y + cellH / 2) * scale;
      const rate = point.pos / point.perf;
      showCellTip(cx, cy, week, bin, rate, point.perf, modelName, seqFill(rate / top));
    } else {
      hideTooltip();
    }
  };
  svg.onfocus = () => paintActive(true);
  svg.onblur = () => {
    outline.setAttribute('visibility', 'hidden');
    hideTooltip();
  };
  svg.onkeydown = (event) => {
    const delta = { ArrowUp: [-1, 0], ArrowDown: [1, 0], ArrowLeft: [0, -1], ArrowRight: [0, 1] }[event.key];
    if (!delta) return;
    event.preventDefault();
    activeRow = Math.min(Math.max(activeRow + delta[0], 0), 4);
    activeCol = Math.min(Math.max(activeCol + delta[1], 0), weeks.length - 1);
    paintActive(true);
  };

  const bar = document.createElement('span');
  bar.className = 'scale-bar';
  bar.style.background = 'linear-gradient(to right, ' + SEQ_STOPS.map((name) => cssVar(name)).join(', ') + ')';
  const scaleText = document.createElement('span');
  scaleText.textContent = '坏账率 0% – ' + (top * 100).toFixed(top * 100 < 10 ? 1 : 0) + '%';
  scaleBox.appendChild(bar);
  scaleBox.appendChild(scaleText);

  renderBinTable(label, suffix, allWeeks, model);
}

function renderBinTable(label, suffix, weeks, model) {
  const box = $('#bin-table-' + suffix);
  box.textContent = '';
  if (!DATA.bins || !DATA.bins.rows[label]) return;
  const table = document.createElement('table');
  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  ['周'].concat([1, 2, 3, 4, 5].map((bin) => '箱 ' + bin)).forEach((text) => {
    const th = document.createElement('th');
    th.textContent = text;
    headRow.appendChild(th);
  });
  thead.appendChild(headRow);
  table.appendChild(thead);

  const tbody = document.createElement('tbody');
  weeks.slice().reverse().forEach((week) => {
    const tr = document.createElement('tr');
    const tdWeek = document.createElement('td');
    tdWeek.textContent = week;
    tr.appendChild(tdWeek);
    for (let bin = 1; bin <= 5; bin++) {
      const point = binPoint(label, week, model, bin);
      const td = document.createElement('td');
      td.textContent = (point && point.perf)
        ? (point.pos / point.perf * 100).toFixed(1) + '% (' + fmtInt.format(point.perf) + ')'
        : '—';
      tr.appendChild(td);
    }
    tbody.appendChild(tr);
  });
  table.appendChild(tbody);
  box.appendChild(table);
}

function distCount(week, model, bin) {
  const byModel = ((DATA.dist && DATA.dist.rows) || {})[week];
  const bins = byModel ? byModel[model] : undefined;
  return bins ? bins[String(bin)] : undefined;
}

function visibleDistWeeks() {
  if (!DATA.dist) return [];
  return state.range === 'all'
    ? DATA.dist.weeks.slice()
    : DATA.dist.weeks.slice(-Number(state.range));
}

function renderDist() {
  const card = $('#dist-card');
  if (!DATA.dist || !DATA.dist.weeks.length) {
    card.hidden = true;
    return;
  }
  card.hidden = false;
  renderDistLegend();
  renderDistChart();
  renderDistTable();
}

function renderDistLegend() {
  const box = $('#dist-legend');
  box.textContent = '';
  for (let bin = 1; bin <= 5; bin++) {
    const item = document.createElement('span');
    item.className = 'item';
    const swatch = document.createElement('span');
    swatch.className = 'swatch';
    swatch.style.background = cssVar('--dist-' + bin);
    item.appendChild(swatch);
    item.appendChild(document.createTextNode('箱 ' + bin));
    box.appendChild(item);
  }
}

function renderDistChart() {
  const svg = $('#dist-chart');
  const empty = $('#dist-empty');
  clearSvg(svg);
  const weeks = visibleDistWeeks();
  const model = state.binModel;
  const modelMeta = buildPayloadMaps().find((item) => item.key === model);
  const modelName = modelMeta ? modelMeta.display : (model || '');

  const totals = weeks.map((week) => {
    let total = 0;
    for (let bin = 1; bin <= 5; bin++) total += distCount(week, model, bin) || 0;
    return total;
  });
  if (!weeks.length || !totals.some((total) => total > 0)) {
    svg.style.display = 'none';
    empty.hidden = false;
    return;
  }
  svg.style.display = 'block';
  empty.hidden = true;

  const DIST_H = 300;
  const plot = { left: M.left, top: M.top, width: SVG_W - M.left - M.right, height: DIST_H - M.top - M.bottom };
  plot.y = (v) => plot.top + (1 - v) * plot.height;
  svg.setAttribute('viewBox', `0 0 ${SVG_W} ${DIST_H}`);

  svgEl('rect', {
    x: plot.left, y: plot.top, width: plot.width, height: plot.height,
    fill: '#fcfcfb', rx: 3,
  }, svg);

  const band = plot.width / weeks.length;
  const barW = Math.min(24, band * 0.62);
  const xOf = (i) => plot.left + (i + 0.5) * band;

  const ticks = [0, 0.25, 0.5, 0.75, 1].map((v) => ({ value: v }));
  drawYAxis(svg, plot, ticks, (v) => Math.round(v * 100) + '%');
  drawXAxis(svg, plot, weeks, xOf, DIST_H);

  weeks.forEach((week, i) => {
    const total = totals[i];
    if (!total) return;
    let cum = 0;
    for (let bin = 1; bin <= 5; bin++) {
      const count = distCount(week, model, bin) || 0;
      if (!count) continue;
      const share = count / total;
      const segTop = plot.top + (1 - cum - share) * plot.height;
      const segH = Math.max(share * plot.height - 2, 1);
      const x = xOf(i) - barW / 2;
      const isTop = cum + share > 0.999999;
      const radius = Math.min(4, segH / 2, barW / 2);
      if (isTop && segH > 2 * radius) {
        const d = `M${x},${segTop + segH} L${x},${segTop + radius}`
          + ` Q${x},${segTop} ${x + radius},${segTop}`
          + ` L${x + barW - radius},${segTop}`
          + ` Q${x + barW},${segTop} ${x + barW},${segTop + radius}`
          + ` L${x + barW},${segTop + segH} Z`;
        svgEl('path', { d, fill: cssVar('--dist-' + bin) }, svg);
      } else {
        svgEl('rect', {
          x, y: segTop, width: barW, height: segH, fill: cssVar('--dist-' + bin),
        }, svg);
      }
      cum += share;
    }
  });

  const crosshair = svgEl('line', {
    y1: plot.top, y2: plot.top + plot.height, stroke: cssVar('--axis'),
    'stroke-width': 1, visibility: 'hidden',
  }, svg);

  attachCrosshair(svg, SVG_W, plot.left, plot.width, weeks, {
    show(index, clientX, clientY) {
      const x = xOf(index);
      crosshair.setAttribute('x1', x);
      crosshair.setAttribute('x2', x);
      crosshair.setAttribute('visibility', 'visible');
      const total = totals[index];
      showTooltip((tip) => {
        const head = document.createElement('div');
        head.className = 'tt-week';
        head.textContent = weeks[index] + (modelName ? ' · ' + modelName : '');
        tip.appendChild(head);
        addTooltipRow(tip, null, '申请量', fmtInt.format(total));
        for (let bin = 1; bin <= 5; bin++) {
          const count = distCount(weeks[index], model, bin) || 0;
          addTooltipRow(
            tip,
            cssVar('--dist-' + bin),
            '箱 ' + bin,
            total ? (count / total * 100).toFixed(1) + '% · ' + fmtInt.format(count) : '—'
          );
        }
      }, clientX, clientY);
    },
    showAt(index) {
      const rect = svg.getBoundingClientRect();
      const scale = rect.width / SVG_W;
      return { x: rect.left + xOf(index) * scale, y: rect.top + plot.top + plot.height / 2 };
    },
    hide() {
      crosshair.setAttribute('visibility', 'hidden');
      hideTooltip();
    },
  });
}

function renderDistTable() {
  const box = $('#dist-table');
  box.textContent = '';
  const weeks = visibleDistWeeks();
  const model = state.binModel;
  if (!DATA.dist) return;
  const table = document.createElement('table');
  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  ['周', '申请量'].concat([1, 2, 3, 4, 5].map((bin) => '箱 ' + bin)).forEach((text) => {
    const th = document.createElement('th');
    th.textContent = text;
    headRow.appendChild(th);
  });
  thead.appendChild(headRow);
  table.appendChild(thead);

  const tbody = document.createElement('tbody');
  weeks.slice().reverse().forEach((week) => {
    let total = 0;
    for (let bin = 1; bin <= 5; bin++) total += distCount(week, model, bin) || 0;
    const tr = document.createElement('tr');
    const cells = [week, total ? fmtInt.format(total) : '—'];
    for (let bin = 1; bin <= 5; bin++) {
      const count = distCount(week, model, bin) || 0;
      cells.push(total ? (count / total * 100).toFixed(1) + '% (' + fmtInt.format(count) + ')' : '—');
    }
    cells.forEach((text) => {
      const td = document.createElement('td');
      td.textContent = text;
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  });
  table.appendChild(tbody);
  box.appendChild(table);
}

function renderAll() {
  $('#meta-source').textContent = DATA.source ? '数据表 ' + DATA.source : '';
  $('#meta-generated').textContent = '生成于 ' + DATA.generatedAt;
  const weeks = visibleWeeks();
  renderKpis(weeks);
  renderLegend();
  renderAucChart(weeks);
  renderCountChart(weeks);
  renderTable(weeks);
  renderFunnel();
  renderBinModelOptions();
  renderBins();
  renderDist();
}

$('#range-select').addEventListener('change', (event) => {
  state.range = event.target.value;
  renderAll();
});

$('#bin-model-select').addEventListener('change', (event) => {
  state.binModel = event.target.value;
  renderBins();
  renderDist();
});

renderPills();
renderVersionPills();
renderAll();

if (window.matchMedia) {
  const media = window.matchMedia('(prefers-color-scheme: dark)');
  const rerender = () => renderAll();
  if (media.addEventListener) media.addEventListener('change', rerender);
  else if (media.addListener) media.addListener(rerender);
}
</script>
</body>
</html>
"""


if __name__ == "__main__":
    raise SystemExit(main())
