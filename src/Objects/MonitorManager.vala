/*-
 * Copyright (c) 2018 elementary LLC.
 *
 * This software is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public
 * License along with this software; if not, write to the
 * Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 *
 * Authored by: Corentin Noël <corentin@elementary.io>
 */

public class Display.MonitorManager : GLib.Object {
    public Gee.LinkedList<Display.VirtualMonitor> virtual_monitors { get; construct; }
    public Gee.LinkedList<Display.Monitor> monitors { get; construct; }

    public bool global_scale_required { get; private set; }
    public bool mirroring_supported { get; private set; }
    public int max_width { get; private set; }
    public int max_height { get; private set; }
    public int monitor_number {
        get {
            return monitors.size;
        }
    }

    public int virtual_monitor_number {
        get {
            return virtual_monitors.size;
        }
    }

    public bool is_mirrored {
        get {
            return virtual_monitors.size == 1 && monitors.size > 1;
        }
    }

    private MutterDisplayConfigInterface iface;
    private uint current_serial;

    private static MonitorManager monitor_manager;
    public static unowned MonitorManager get_default () {
        if (monitor_manager == null) {
            monitor_manager = new MonitorManager ();
        }

        return monitor_manager;
    }

    private MonitorManager () {
        get_monitor_config ();
    }

    construct {
        monitors = new Gee.LinkedList<Display.Monitor> ();
        virtual_monitors = new Gee.LinkedList<Display.VirtualMonitor> ();
        try {
            iface = Bus.get_proxy_sync (BusType.SESSION, "org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig");
            iface.monitors_changed.connect (get_monitor_config);
        } catch (Error e) {
            critical (e.message);
        }
    }

    public void get_monitor_config () {
        monitors.clear ();
        virtual_monitors.clear ();

        MutterReadMonitor[] mutter_monitors;
        MutterReadLogicalMonitor[] mutter_logical_monitors;
        GLib.HashTable<string, GLib.Variant> properties;
        try {
            iface.get_current_state (out current_serial, out mutter_monitors, out mutter_logical_monitors, out properties);
        } catch (Error e) {
            critical (e.message);
        }

        //TODO: make use of the "global-scale-required" property to differenciate between X and Wayland
        var supports_mirroring_variant = properties.lookup ("supports-mirroring");
        if (supports_mirroring_variant != null) {
            mirroring_supported = supports_mirroring_variant.get_boolean ();
        } else {
            /*
             * Absence of "supports-mirroring" means true according to the documentation.
             */
            mirroring_supported = true;
        }

        var global_scale_required_variant = properties.lookup ("global-scale-required");
        if (global_scale_required_variant != null) {
            global_scale_required = global_scale_required_variant.get_boolean ();
        } else {
            /*
             * Absence of "global-scale-required" means false according to the documentation.
             */
            global_scale_required = false;
        }

        var max_screen_size_variant = properties.lookup ("max-screen-size");
        if (max_screen_size_variant != null) {
            max_width = max_screen_size_variant.get_child_value (0).get_int32 ();
            max_height = max_screen_size_variant.get_child_value (1).get_int32 ();
        } else {
            /*
             * Absence of "supports-mirroring" means true according to the documentation.
             */
            max_width = int.MAX;
            max_height = int.MAX;
        }

        var monitors_with_changed_modes = new Gee.LinkedList<Display.Monitor> ();
        foreach (var mutter_monitor in mutter_monitors) {
            var monitor = new Display.Monitor ();

            monitors.add (monitor);
            monitor.connector = mutter_monitor.monitor.connector;
            monitor.vendor = mutter_monitor.monitor.vendor;
            monitor.product = mutter_monitor.monitor.product;
            monitor.serial = mutter_monitor.monitor.serial;

            var display_name_variant = mutter_monitor.properties.lookup ("display-name");
            if (display_name_variant != null) {
                monitor.display_name = display_name_variant.get_string ();
            } else {
                monitor.display_name = monitor.connector;
            }

            var is_builtin_variant = mutter_monitor.properties.lookup ("is-builtin");
            if (is_builtin_variant != null) {
                monitor.is_builtin = is_builtin_variant.get_boolean ();
            } else {
                /*
                 * Absence of "is-builtin" means it's not according to the documentation.
                 */
                monitor.is_builtin = false;
            }

            foreach (var mutter_mode in mutter_monitor.modes) {
                var mode = new Display.MonitorMode ();

                mode.id = mutter_mode.id;
                mode.width = mutter_mode.width;
                mode.height = mutter_mode.height;
                mode.frequency = mutter_mode.frequency;
                mode.preferred_scale = mutter_mode.preferred_scale;
                mode.supported_scales = mutter_mode.supported_scales;
                var is_preferred_variant = mutter_mode.properties.lookup ("is-preferred");
                if (is_preferred_variant != null) {
                    mode.is_preferred = is_preferred_variant.get_boolean ();
                } else {
                    mode.is_preferred = false;
                }

                var is_current_variant = mutter_mode.properties.lookup ("is-current");
                if (is_current_variant != null) {
                    mode.is_current = is_current_variant.get_boolean ();
                } else {
                    mode.is_current = false;
                }

                monitor.modes.add (mode);
            }
        }

        foreach (var mutter_logical_monitor in mutter_logical_monitors) {
            var virtual_monitor = new VirtualMonitor ();

            virtual_monitor.x = mutter_logical_monitor.x;
            virtual_monitor.y = mutter_logical_monitor.y;
            virtual_monitor.current_x = mutter_logical_monitor.x;
            virtual_monitor.current_y = mutter_logical_monitor.y;
            virtual_monitor.scale = mutter_logical_monitor.scale;
            virtual_monitor.transform = mutter_logical_monitor.transform;
            virtual_monitor.primary = mutter_logical_monitor.primary;
            foreach (var mutter_info in mutter_logical_monitor.monitors) {
                foreach (var monitor in monitors) {
                    if (compare_monitor_with_mutter_info (monitor, mutter_info) && !(monitor in virtual_monitor.monitors)) {
                        virtual_monitor.monitors.add (monitor);
                        if (monitor in monitors_with_changed_modes) {
                            virtual_monitor.modes_changed ();
                        }

                        break;
                    }
                }
            }

            add_virtual_monitor (virtual_monitor);
        }

        notify_property ("virtual-monitor-number");
        notify_property ("monitor-number");
        notify_property ("is-mirrored");
    }

    public void set_monitor_config () {
        MutterWriteLogicalMonitor[] logical_monitors = {};
        foreach (var virtual_monitor in virtual_monitors) {
            logical_monitors += get_mutter_logical_monitor (virtual_monitor);
        }

        var properties = new GLib.HashTable<string, GLib.Variant> (str_hash, str_equal);
        try {
            iface.apply_monitors_config (current_serial, MutterApplyMethod.PERSISTENT, logical_monitors, properties);
        } catch (Error e) {
            critical (e.message);
        }
    }

    public static MutterWriteLogicalMonitor get_mutter_logical_monitor (Display.VirtualMonitor virtual_monitor) {
        var logical_monitor = MutterWriteLogicalMonitor () {
            x = virtual_monitor.x,
            y = virtual_monitor.y,
            scale = virtual_monitor.scale,
            transform = virtual_monitor.transform,
            primary = virtual_monitor.primary
        };

        MutterWriteMonitor[] mutter_monitors = {};
        foreach (var monitor in virtual_monitor.monitors) {
            var properties = new GLib.HashTable<string, GLib.Variant> (str_hash, str_equal);
            var mutter_monitor = MutterWriteMonitor () {
                connector = monitor.connector,
                monitor_mode = monitor.current_mode.id,
                properties = properties
            };

            mutter_monitors += mutter_monitor;
        }

        logical_monitor.monitors = mutter_monitors;
        return logical_monitor;
    }

    //TODO: check for compatibility of displays in the same virtualmonitor.
    public bool enable_clone_mode () {
        if (is_mirrored) {
            return false;
        }

        var clone_virtual_monitor = new Display.VirtualMonitor ();
        clone_virtual_monitor.primary = true;

        var max_compatible_scale = Utils.get_max_compatible_scale (monitors);
        /* Reduce actual scale to smallest one in use (for X will only be one anyway? ) */
        foreach (var vmon in virtual_monitors) {
            max_compatible_scale = double.min (max_compatible_scale, vmon.scale);
        }

        clone_virtual_monitor.scale = max_compatible_scale;
        clone_virtual_monitor.monitors.add_all (monitors);

        var modes = clone_virtual_monitor.get_available_modes ();
        /*
         * Two choices here:
         *  - Use the largest resolution already in use.
         *  - Fallback to the largest resultion available.
         */
        Display.MonitorMode? largest_mode_in_use = null;
        Display.MonitorMode largest_mode = modes.get (0);
        foreach (var mode in modes) {
            if (mode.is_current) {
                if (largest_mode_in_use == null) {
                    largest_mode_in_use = mode;
                } else if (largest_mode_in_use.width < mode.width) {
                    largest_mode_in_use = mode;
                }
            }

            // If there is one compatible setting, stop computing the fallback
            if (largest_mode_in_use == null) {
                if (largest_mode == null) {
                    largest_mode = mode;
                } else if (largest_mode.width < mode.width) {
                    largest_mode = mode;
                }
            }
        }

        var mode_to_set = largest_mode_in_use ?? largest_mode;
        clone_virtual_monitor.set_current_mode (mode_to_set);

        warning ("Set virtual clone monitor mode to %s and scale to %f", mode_to_set.get_resolution (), max_compatible_scale);

        virtual_monitors.clear ();
        virtual_monitors.add (clone_virtual_monitor);

        notify_property ("virtual-monitor-number");
        notify_property ("is-mirrored");


        return true;
    }

    public void set_scale_on_all_monitors (double new_scale) {
        if (new_scale <= 0.0) {
            return;
        }

        double max_scale = Utils.get_max_compatible_scale (monitors);
        if (new_scale > max_scale) {
            return;
        }

        foreach (var monitor in virtual_monitors) {
            monitor.scale = new_scale;
        }

        set_monitor_config ();
    }

    public bool disable_clone_mode () {
        var clone_virtual_monitor = virtual_monitors[0];
        virtual_monitors.clear ();
        foreach (var monitor in clone_virtual_monitor.monitors) {
            var single_virtual_monitor = new Display.VirtualMonitor ();

            if (global_scale_required) {
                single_virtual_monitor.scale = clone_virtual_monitor.scale;
            } else {
                single_virtual_monitor.scale = monitor.preferred_mode.preferred_scale;
            }

            monitor.current_mode.is_current = false;
            monitor.preferred_mode.is_current = true;

            single_virtual_monitor.monitors.add (monitor);
            if (monitor.is_builtin) {
                single_virtual_monitor.primary = true;
            }

            virtual_monitors.add (single_virtual_monitor);
        }

        notify_property ("virtual-monitor-number");
        notify_property ("is-mirrored");

        return true;
    }

    private void add_virtual_monitor (Display.VirtualMonitor virtual_monitor) {
        virtual_monitors.add (virtual_monitor);
        notify_property ("virtual-monitor-number");
    }

    private static bool compare_monitor_with_mutter_info (Display.Monitor monitor, MutterReadMonitorInfo mutter_info) {
        return monitor.connector == mutter_info.connector
               && monitor.vendor == mutter_info.vendor
               && monitor.product == mutter_info.product
               && monitor.serial == mutter_info.serial;
    }
}
