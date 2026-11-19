using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace EdgeBox {
    public sealed class ServiceRecoveryState {
        public uint ResetPeriod { get; set; }
        public string ServiceIdentityDigest { get; set; }
        public int[] Types { get; set; }
        public uint[] Delays { get; set; }
        public string MessageAndCommandDigest { get; set; }
    }

    public static class ServiceRecovery {
        // SERVICE_FAILURE_ACTIONSW. Pointers must retain native alignment on x86 and x64.
        [StructLayout(LayoutKind.Sequential)]
        private struct FailureActions {
            public uint ResetPeriod;
            public IntPtr RebootMessage, Command;
            public uint Count;
            public IntPtr Actions;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Configuration {
            public uint Type, Start, ErrorControl;
            public IntPtr BinaryPath, LoadGroup;
            public uint Tag;
            public IntPtr Dependencies, Account, DisplayName;
        }

        private sealed class ServiceHandle : SafeHandleZeroOrMinusOneIsInvalid {
            private ServiceHandle() : base(true) {}
            protected override bool ReleaseHandle() { return CloseServiceHandle(handle); }
        }

        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern ServiceHandle OpenSCManager(string machine, string database, uint access);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern ServiceHandle OpenService(ServiceHandle scm, string name, uint access);
        [DllImport("advapi32.dll", SetLastError=true)]
        private static extern bool CloseServiceHandle(IntPtr handle);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern bool QueryServiceConfig(ServiceHandle service, IntPtr buffer, uint size, out uint needed);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern bool QueryServiceConfig2(ServiceHandle service, uint level, IntPtr buffer, uint size, out uint needed);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern bool ChangeServiceConfig2(ServiceHandle service, uint level, ref FailureActions value);

        private static ServiceHandle Open(string name, uint access) {
            using (ServiceHandle scm = OpenSCManager(null, null, 1)) {
                if (scm.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                ServiceHandle service = OpenService(scm, name, access);
                if (service.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                return service;
            }
        }

        private static IntPtr Query(ServiceHandle service, uint level) {
            uint size;
            QueryServiceConfig2(service, level, IntPtr.Zero, 0, out size);
            int error = Marshal.GetLastWin32Error();
            if (error != 122 || size == 0) throw new Win32Exception(error);
            IntPtr buffer = Marshal.AllocHGlobal(checked((int)size));
            if (QueryServiceConfig2(service, level, buffer, size, out size)) return buffer;
            error = Marshal.GetLastWin32Error();
            Marshal.FreeHGlobal(buffer);
            throw new Win32Exception(error);
        }

        private static string IdentityDigest(ServiceHandle service) {
            uint size;
            QueryServiceConfig(service, IntPtr.Zero, 0, out size);
            int error = Marshal.GetLastWin32Error();
            if (error != 122 || size == 0) throw new Win32Exception(error);
            IntPtr buffer = Marshal.AllocHGlobal(checked((int)size));
            try {
                if (!QueryServiceConfig(service, buffer, size, out size)) throw new Win32Exception(Marshal.GetLastWin32Error());
                Configuration config = (Configuration)Marshal.PtrToStructure(buffer, typeof(Configuration));
                StringBuilder identity = new StringBuilder();
                identity.Append(config.Type).Append(',').Append(config.Start).Append(',').Append(config.ErrorControl).Append(',').Append(config.Tag);
                foreach (IntPtr field in new IntPtr[] { config.BinaryPath, config.LoadGroup, config.Account, config.DisplayName })
                    identity.Append('\0').Append(Marshal.PtrToStringUni(field));
                IntPtr dependency = config.Dependencies;
                while (dependency != IntPtr.Zero && Marshal.ReadInt16(dependency) != 0) {
                    string item = Marshal.PtrToStringUni(dependency);
                    identity.Append('\0').Append(item);
                    dependency = IntPtr.Add(dependency, 2 * (item.Length + 1));
                }
                IntPtr flags = Query(service, 4);
                try { identity.Append('\0').Append(Marshal.ReadInt32(flags)); }
                finally { Marshal.FreeHGlobal(flags); }
                using (SHA256 sha = SHA256.Create()) {
                    return BitConverter.ToString(sha.ComputeHash(Encoding.Unicode.GetBytes(identity.ToString()))).Replace("-", "");
                }
            } finally { Marshal.FreeHGlobal(buffer); }
        }

        private static ServiceRecoveryState Read(ServiceHandle service) {
            IntPtr buffer = Query(service, 2);
            try {
                FailureActions value = (FailureActions)Marshal.PtrToStructure(buffer, typeof(FailureActions));
                int count = checked((int)value.Count);
                int[] types = new int[count];
                uint[] delays = new uint[count];
                for (int index = 0; index < count; index++) {
                    types[index] = Marshal.ReadInt32(value.Actions, index * 8);
                    delays[index] = unchecked((uint)Marshal.ReadInt32(value.Actions, index * 8 + 4));
                }
                string message = Marshal.PtrToStringUni(value.RebootMessage) ?? "";
                string command = Marshal.PtrToStringUni(value.Command) ?? "";
                using (SHA256 sha = SHA256.Create()) {
                    return new ServiceRecoveryState { ResetPeriod=value.ResetPeriod, Types=types, Delays=delays, ServiceIdentityDigest=IdentityDigest(service),
                        MessageAndCommandDigest=BitConverter.ToString(sha.ComputeHash(Encoding.Unicode.GetBytes(message + "\0" + command))).Replace("-", "") };
                }
            } finally { Marshal.FreeHGlobal(buffer); }
        }

        public static ServiceRecoveryState Read(string name) {
            using (ServiceHandle service = Open(name, 1)) { return Read(service); }
        }

        public static int[] GetReplacementTypes(ServiceRecoveryState current, ServiceRecoveryState expected) {
            if (expected == null || expected.ResetPeriod != current.ResetPeriod ||
                expected.ServiceIdentityDigest != current.ServiceIdentityDigest || expected.MessageAndCommandDigest != current.MessageAndCommandDigest ||
                expected.Types.Length != current.Types.Length || expected.Delays.Length != current.Delays.Length)
                throw new InvalidOperationException("SERVICE_RECOVERY_CHANGED");
            int[] types = (int[])current.Types.Clone();
            for (int i = 0; i < types.Length; i++) {
                if (types[i] != expected.Types[i] || current.Delays[i] != expected.Delays[i])
                    throw new InvalidOperationException("SERVICE_RECOVERY_CHANGED");
                if (types[i] == 2) types[i] = 1;
            }
            return types;
        }

        public static void ReplaceReboots(string name, ServiceRecoveryState expected) {
            // SCM requires QUERY_CONFIG, CHANGE_CONFIG and START to configure SC_ACTION_RESTART.
            using (ServiceHandle service = Open(name, 1 | 2 | 16)) {
                IntPtr protection = Query(service, 12);
                try {
                    if (Marshal.ReadInt32(protection) != 0) throw new InvalidOperationException("SERVICE_LAUNCH_PROTECTED");
                } finally { Marshal.FreeHGlobal(protection); }
                ServiceRecoveryState current = Read(service);
                int[] types = GetReplacementTypes(current, expected);
                int count = types.Length;
                if (Array.IndexOf(current.Types, 2) < 0) return;
                IntPtr actions = Marshal.AllocHGlobal(checked(count * 8));
                try {
                    for (int i = 0; i < count; i++) {
                        Marshal.WriteInt32(actions, i * 8, types[i]);
                        Marshal.WriteInt32(actions, i * 8 + 4, unchecked((int)current.Delays[i]));
                    }
                    // NULL message and command leave SCM's strings unchanged, including third-party commands.
                    FailureActions change = new FailureActions { ResetPeriod=current.ResetPeriod, Count=(uint)count, Actions=actions };
                    if (!ChangeServiceConfig2(service, 2, ref change)) throw new Win32Exception(Marshal.GetLastWin32Error());
                } finally { Marshal.FreeHGlobal(actions); }
            }
        }
    }
}
