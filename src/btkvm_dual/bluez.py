"""Authenticated custom BlueZ Profile1, independent of HID and A2DP."""
import os
import struct

import dbus
import dbus.service

from .runtime import SERVICE_UUID, RFCOMM_CHANNEL, wrap_rfcomm_fd


class DualProfile(dbus.service.Object):
    def __init__(self, bus, runtime, host_file, logger):
        super().__init__(bus, "/org/btkvm/dual")
        self.bus, self.runtime, self.host_file, self.log = bus, runtime, host_file, logger
        self.device = None

    @dbus.service.method("org.bluez.Profile1", in_signature="", out_signature="")
    def Release(self):
        self.runtime.detach_rfcomm()

    @dbus.service.method("org.bluez.Profile1", in_signature="oha{sv}", out_signature="")
    def NewConnection(self, device, fd, properties):
        conn = wrap_rfcomm_fd(fd.take())
        try:
            props = dbus.Interface(self.bus.get_object("org.bluez", device),
                                   "org.freedesktop.DBus.Properties")
            paired = bool(props.Get("org.bluez.Device1", "Paired"))
            address = str(props.Get("org.bluez.Device1", "Address"))
            with open(self.host_file) as source:
                expected = source.read().strip()
            # RequireAuthentication asks BlueZ for medium security. Check the
            # kernel's actual level as well; never silently allow a clear link.
            security = conn.getsockopt(274, 4, 2)  # SOL_BLUETOOTH, BT_SECURITY
            if not paired or not expected or address.upper() != expected.upper() or security[0] < 2:
                raise ValueError("requires encrypted Bluetooth from the registered HID host")
            conn.setsockopt(274, 4, struct.pack("BB", 2, 0))
            conn.setsockopt(1, 7, 2048)  # SOL_SOCKET, SO_SNDBUF
            self.device = str(device)
            self.runtime.attach_rfcomm(conn)
            self.log(f"dual: RFCOMM autenticado de {address}")
        except Exception as exc:
            conn.close()
            self.log(f"dual: RFCOMM recusado: {exc}")
            raise dbus.exceptions.DBusException("RFCOMM authorization failed",
                                                name="org.bluez.Error.Rejected")

    @dbus.service.method("org.bluez.Profile1", in_signature="o", out_signature="")
    def RequestDisconnection(self, device):
        if str(device) == self.device:
            self.runtime.detach_rfcomm()
            self.device = None


def register(bus, manager, runtime, host_file, logger):
    profile = DualProfile(bus, runtime, host_file, logger)
    record = f'''<?xml version="1.0" encoding="UTF-8"?>
<record>
 <attribute id="0x0001"><sequence><uuid value="{SERVICE_UUID}"/></sequence></attribute>
 <attribute id="0x0004"><sequence>
  <sequence><uuid value="0x0100"/></sequence>
  <sequence><uuid value="0x0003"/><uint8 value="0x{RFCOMM_CHANNEL:02x}"/></sequence>
 </sequence></attribute>
 <attribute id="0x0005"><sequence><uuid value="0x1002"/></sequence></attribute>
 <attribute id="0x0100"><text value="btkvm dual"/></attribute>
</record>'''
    manager.RegisterProfile(profile, SERVICE_UUID, {
        "Name": "btkvm dual", "Role": "server", "Channel": dbus.UInt16(RFCOMM_CHANNEL),
        "ServiceRecord": record,
        "RequireAuthentication": True, "RequireAuthorization": False,
        "AutoConnect": False,
    })
    return profile
