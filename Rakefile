# frozen_string_literal: true

require "rake/testtask"

desc "Generate RBS signatures from inline annotations"
task :rbs do
  rb_files = FileList["lib/**/*.rb"]
  sh "bundle exec rbs-inline --output -- #{rb_files.join(' ')}"
end

desc "Run steep type checker (generates RBS first)"
task typecheck: :rbs do
  sh "bundle exec steep check"
end

# Files syntax_tree owns.
#
# `Rakefile` and the gemspec are deliberately absent — neither matches
# stree's output today, and pulling them in would mean reformatting
# files this task exists to guard rather than to change.
FORMAT_FILES = FileList["lib/**/*.rb", "test/**/*.rb"]

desc "Check formatting matches syntax_tree"
task :format_check do
  sh "bundle exec stree check #{FORMAT_FILES.join(" ")}" do |ok, _res|
    abort "Formatting differs from syntax_tree. Run `rake format`." unless ok
  end
end

desc "Reformat with syntax_tree"
task :format do
  sh "bundle exec stree write #{FORMAT_FILES.join(" ")}"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
end

# Formatting runs first: it is the cheapest check, and syntax_tree has
# been seen to change a hash key's *type* rather than only its layout,
# so an unformatted tree is worth surfacing before anything else.
task default: %i[format_check typecheck test]
