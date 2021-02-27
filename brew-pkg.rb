# Builds an OS X installer package from an installed formula.
require 'formula'
require 'optparse'
require 'tmpdir'

module HomebrewArgvExtension extend self
  def with_deps?
    flag? '--with-deps'
  end
end

# cribbed Homebrew module code from brew-unpack.rb
module Homebrew extend self
  def pkg
    unpack_usage = <<-EOS
Usage: brew pkg [--identifier-prefix] [--with-deps] [--without-kegs] formula

Build an OS X installer package from a formula. It must be already
installed; 'brew pkg' doesn't handle this for you automatically. The
'--identifier-prefix' option is strongly recommended in order to follow
the conventions of OS X installer packages.

Options:
  --identifier-prefix     set a custom identifier prefix to be prepended
                          to the built package's identifier, ie. 'org.nagios'
                          makes a package identifier called 'org.nagios.nrpe'
  --with-deps             include all the package's dependencies in the built package
  --without-kegs          exclude package contents at /usr/local/Cellar/packagename
  --scripts               set the path to custom preinstall and postinstall scripts
    EOS

    abort unpack_usage if ARGV.empty?
    identifier_prefix = if ARGV.include? '--identifier-prefix'
      ARGV.next.chomp(".")
    else
      'org.homebrew'
    end

    f = Formulary.factory ARGV.last
    # raise FormulaUnspecifiedError if formulae.empty?
    # formulae.each do |f|
    name = f.name
    identifier = identifier_prefix + ".#{name}"
    version = f.version.to_s
    version += "_#{f.revision}" if f.revision.to_s != '0'

    # Make sure it's installed first
    if not f.any_version_installed?
      onoe "#{f.name} is not installed. First install it with 'brew install #{f.name}'."
      abort
    end

    # Setup staging dir
    pkg_root = Dir.mktmpdir 'brew-pkg'
    staging_root = pkg_root + HOMEBREW_PREFIX
    ohai "Creating package staging root using Homebrew prefix #{HOMEBREW_PREFIX}"
    FileUtils.mkdir_p staging_root


    pkgs = [f]

    # Add deps if we specified --with-deps
    pkgs += f.recursive_dependencies if ARGV.include? '--with-deps'

    pkgs.each do |pkg|
      formula = Formulary.factory(pkg.to_s)
      dep_version = formula.version.to_s
      dep_version += "_#{formula.revision}" if formula.revision.to_s != '0'


      ohai "Staging formula #{formula.name}"
      # Get all directories for this keg, rsync to the staging root

      if File.exists?(File.join(HOMEBREW_CELLAR, formula.name, dep_version))

        dirs = Pathname.new(File.join(HOMEBREW_CELLAR, formula.name, dep_version)).children.select { |c| c.directory? }.collect { |p| p.to_s }
        # This works through the original prefix tree and preserves the links so that the resulting package reproduces
        # same the full tree as is so that Homebrew can work with the files after the fact.

        # For each directory in the Cellar found
        dirs.each do |d|
          # If its in the magic list of approved directories, proceed
          ohai "Copy #{d} to #{staging_root}"
          if d =~ /bin|etc|sbin|include|share|lib|Frameworks$/
            # Get the file/directory name
            rel_dir = File.basename(d)
            # Iterate over everything in that original path
            Dir.foreach(d) do |filename|
              next if filename == "." or filename == ".."
              # If it exists in the main tree and is directory, make it in staging
              if File.directory?(File.join(HOMEBREW_PREFIX, rel_dir, filename))
                safe_system "mkdir", "-p", File.join(staging_root, rel_dir, filename)
                # If its a symlink in the main tree, copy it over to the staging directory
              elsif File.symlink?(File.join(HOMEBREW_PREFIX, rel_dir, filename))
                safe_system "rsync", "-a", File.join(HOMEBREW_PREFIX, rel_dir, filename), "#{staging_root}/#{rel_dir}/"
              end
            end
          end
        end


        if File.exists?("#{HOMEBREW_CELLAR}/#{formula.name}/#{dep_version}") and not ARGV.include? '--without-kegs'

          ohai "Staging directory #{HOMEBREW_CELLAR}/#{formula.name}/#{dep_version}"

          safe_system "mkdir", "-p", "#{staging_root}/Cellar/#{formula.name}/"
          safe_system "rsync", "-a", "#{HOMEBREW_CELLAR}/#{formula.name}/#{dep_version}", "#{staging_root}/Cellar/#{formula.name}/"
        end

      end

      # Add PREFIX/var/homebrew/linked for interal Homebrew internal
      stripped_name = formula.name.split("@")[0]
      if File.exists?("#{HOMEBREW_LINKED_KEGS}/#{formula.name}")
        safe_system "mkdir", "-p", "#{staging_root}/var/homebrew/linked/"
        # Greedy grab any link we find, this might be over-aggressive but better than them missing
        Dir.glob("#{HOMEBREW_LINKED_KEGS}/*#{stripped_name}*") do |link_path|
          link_filename = File.basename(link_path)
          safe_system "rsync", "-a", "#{link_path}", "#{staging_root}/var/homebrew/linked/#{link_filename}"
        end
      end

      # Python is special cased in that site-packages is global in #{HOMEBREW_PREFIX}/lib/ instead of Cellar
      if stripped_name == "python"
        py_version = formula.name.split("@")[1]
        safe_system "rsync", "-a", "#{HOMEBREW_PREFIX}/lib/#{stripped_name}#{py_version}", "#{staging_root}/lib/"
      end

      # Add in the opt prefix link to allow Homebrew to reason about latest
      if formula.optlinked? && File.exists?(formula.opt_prefix)
        safe_system "mkdir", "-p", "#{staging_root}/opt"
        Dir.glob("#{HOMEBREW_PREFIX}/opt/*#{stripped_name}*") do |link_path|
          link_filename = File.basename(link_path)
          safe_system "rsync", "-a", "#{link_path}", "#{staging_root}/opt/#{link_filename}"
        end
      end

      # Write out a LaunchDaemon plist if we have one
      if formula.plist
        ohai "Plist found at #{formula.plist_name}, staging for /Library/LaunchDaemons/#{formula.plist_name}.plist"
        launch_daemon_dir = File.join staging_root, "Library", "LaunchDaemons"
        FileUtils.mkdir_p launch_daemon_dir
        fd = File.new(File.join(launch_daemon_dir, "#{formula.plist_name}.plist"), "w")
        fd.write formula.plist
        fd.close
      end
    end

    # Add scripts if we specified --scripts 
    found_scripts = false
    if ARGV.include? '--scripts'
      scripts_path = ARGV.next
      if File.directory?(scripts_path)
        pre = File.join(scripts_path,"preinstall")
        post = File.join(scripts_path,"postinstall")
        if File.exists?(pre)
          File.chmod(0755, pre)
          found_scripts = true
          ohai "Adding preinstall script"
        end
        if File.exists?(post)
          File.chmod(0755, post)
          found_scripts = true
          ohai "Adding postinstall script"
        end
      end
      if not found_scripts
        opoo "No scripts found in #{scripts_path}"
      end
    end

    # Custom ownership
    found_ownership = false
    if ARGV.include? '--ownership'
      custom_ownership = ARGV.next
       if ['recommended', 'preserve', 'preserve-other'].include? custom_ownership
        found_ownership = true
        ohai "Setting pkgbuild option --ownership with value #{custom_ownership}"
       else
        opoo "#{custom_ownership} is not a valid value for pkgbuild --ownership option, ignoring"
       end
    end

    # Build it
    pkgfile = "#{name}-#{version}.pkg"
    ohai "Building package #{pkgfile}"
    args = [
      "--quiet",
      "--root", "#{pkg_root}",
      "--identifier", identifier,
      "--version", version
    ]
    if found_scripts
      args << "--scripts"
      args << scripts_path 
    end
    if found_ownership
      args << "--ownership"
      args << custom_ownership 
    end
    args << "#{pkgfile}"
    safe_system "pkgbuild", *args

    FileUtils.rm_rf pkg_root
  end
end

Homebrew.pkg
