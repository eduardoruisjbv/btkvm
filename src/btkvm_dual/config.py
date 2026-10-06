"""Optional flat key=value configuration; no file means the original HID mode."""
from pathlib import Path


def load(path="/etc/btkvm.conf"):
    values = {"modo": "hid", "udp_host": "0.0.0.0", "udp_port": "45873"}
    config = Path(path)
    if config.exists():
        for number, line in enumerate(config.read_text().splitlines(), 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            key, separator, value = line.partition("=")
            key, value = key.strip(), value.strip()
            if not separator or key not in values:
                raise ValueError(f"{path}:{number}: configuração inválida")
            values[key] = value
    if values["modo"] not in ("hid", "dual"):
        raise ValueError("modo deve ser hid ou dual")
    values["udp_port"] = int(values["udp_port"])
    if not 1 <= values["udp_port"] <= 65535:
        raise ValueError("udp_port deve estar entre 1 e 65535")
    return values
