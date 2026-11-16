# This file is used to generate Qt symbols used by crashlab
# to add stack traces to exceptions
# 
# This will generate a symbol hierarchy in the output folder.
# These symbols must be uploaded to CSI
# All files in `syms` folder should go in `/opt/qtsyms/<version>/<platform>/` like `/opt/qtsyms/5.11.1/win64/`

require_relative 'model/build'
require_relative 'util/dumpsyms'
require 'tempfile'

class MakeQtSymbols
    $DEPS_PATH = File.expand_path(File.join(File.dirname(__FILE__), "..", "deps"))
    $LIB_LIST = ["Core", "Gui", "Qml", "QuickControls2", "Network", "Quick", "Widgets", "QuickTemplates2"]

    def self.process_symbols output_dir
        lib_path = "#{Executable::Qt.targetQtRoot}/lib/"
        additional_suffixes = [".5"]
        # Libs required for our application
        if Build.windows?
            # Qt's debug information packages put the PDBs next to the DLLs
            # in bin/ (older releases used lib/)
            bin_path = "#{Executable::Qt.targetQtRoot}/bin/"
            $LIB_LIST.each do |i|
                pdb = [bin_path, lib_path].map { |d| File.join(d, "Qt6#{i}.pdb") }.find { |f| File.exist?(f) }
                raise "Qt6#{i}.pdb not found in #{bin_path} or #{lib_path} (install Qt's debug information, or set SKIP_QT_DEBUG_SYMBOLS=1)" unless pdb
                DumpSyms.dump_syms(pdb, output_dir, additional_suffixes)
            end
        elsif Build.macos?
            $LIB_LIST.each do |i|
                DumpSyms.dump_syms(File.join(lib_path, "Qt#{i}.Framework/Qt#{i}"), output_dir, additional_suffixes)
            end
            DumpSyms.dump_syms(File.join(lib_path, "../plugins/platforms/libqcocoa.dylib"), output_dir, additional_suffixes)
        elsif Build.linux?
            $LIB_LIST.each do |i|
                DumpSyms.dump_syms(File.join(lib_path, "libQt6#{i}.so"), output_dir, additional_suffixes)
            end
            DumpSyms.dump_syms(File.join(lib_path, "libQt6XcbQpa.so"), output_dir, additional_suffixes)
        end
    end
end
