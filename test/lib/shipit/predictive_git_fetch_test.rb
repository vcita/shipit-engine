# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'tmpdir'

module Shipit
  class PredictiveGitFetchTest < ActiveSupport::TestCase
    BRANCH = 'PREDICTIVE-BRANCH-1'

    setup do
      @tmp = Dir.mktmpdir
      @origin = File.join(@tmp, 'origin')
      @cache = File.join(@tmp, 'cache')
      @workdir = File.join(@tmp, 'task')

      git(@tmp, 'init', '-q', '-b', 'master', @origin)
      commit_spec(@origin, 'echo old-run')
      # The cache is cloned while the stack branch has the old shipit.yml. Fetches of predictive branches do
      # not move the cache's own branch afterwards.
      git(@tmp, 'clone', '-q', @origin, @cache)
      git(@origin, 'checkout', '-q', '-b', BRANCH)
      commit_spec(@origin, 'echo new-run')

      Stack.any_instance.stubs(:git_path).returns(@cache)
      Stack.any_instance.stubs(:repo_git_url).returns(@origin)

      pipeline = Pipeline.create!(name: 'git-fetch-test', environment: 'production')
      @build = PredictiveBuild.create!(pipeline: pipeline, branch: BRANCH)
      @task = PredictiveBuildTask.create!(stack: shipit_stacks(:shipit), user: shipit_users(:walrus),
                                          predictive_build: @build, predictive_task_type: 'run')
      @task.stubs(:working_directory).returns(@workdir)
    end

    teardown do
      FileUtils.rm_rf(@tmp)
    end

    test "a pipeline task runs the commands of the predictive branch's shipit.yml" do
      commands = Commands.for(@task)
      commands.fetch(@build)

      assert_equal BRANCH, git(@workdir, 'rev-parse', '--abbrev-ref', 'HEAD').strip
      assert_equal ['echo new-run'], commands.steps
    end

    private

    def commit_spec(dir, run_command)
      File.write(File.join(dir, 'shipit.yml'), { 'ci' => { 'pipeline' => { 'run' => [run_command] } } }.to_yaml)
      git(dir, 'add', 'shipit.yml')
      git(dir, '-c', 'user.name=test', '-c', 'user.email=test@example.com', 'commit', '-q', '-m', run_command)
    end

    def git(dir, *args)
      output, status = Open3.capture2e('git', *args, chdir: dir)
      raise "git #{args.join(' ')} failed: #{output}" unless status.success?
      output
    end
  end
end
