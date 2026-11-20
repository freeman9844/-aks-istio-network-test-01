"""bash 에서 `python3 -m aksnetval.<모듈> <함수> '<JSON kwargs>'` 로 부르기 위한 공통 진입점."""
import dataclasses
import json
import sys


def run(module_globals: dict, argv: list[str]) -> int:
    if not argv:
        print("사용법: <함수> ['<JSON kwargs>']", file=sys.stderr)
        return 2
    name, raw = argv[0], (argv[1] if len(argv) > 1 else "{}")
    fn = module_globals.get(name)
    if name.startswith("_") or not callable(fn):
        print(f"알 수 없는 함수: {name}", file=sys.stderr)
        return 2
    kwargs = json.loads(raw)
    # "@경로" 문자열 값은 해당 JSON 파일 내용으로 바꾼다(kubectl 출력이 커서 인자로 넘기기 어려움)
    for k, v in kwargs.items():
        if isinstance(v, str) and v.startswith("@"):
            with open(v[1:], encoding="utf-8") as f:
                kwargs[k] = json.load(f)
    result = fn(**kwargs)
    if dataclasses.is_dataclass(result):
        result = dataclasses.asdict(result)
    elif isinstance(result, str):
        result = {"verdict": result}
    print(json.dumps(result, ensure_ascii=False))
    return 0
