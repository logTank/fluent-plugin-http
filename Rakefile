#!/usr/bin/env rake
require "bundler/gem_tasks"

require 'rake/testtask'

desc 'Run test_unit based test'
Rake::TestTask.new(:test) do |t|
  t.libs << 'lib' << "test"
  t.test_files = Dir["test/**/test_*.rb"].sort
  t.verbose = true
  #t.warning = true
end

desc 'Run test with simplecov'
task :coverage do |t|
  ENV['SIMPLE_COV'] = '1'
  Rake::Task["test"].invoke
end

task :default => [:test]