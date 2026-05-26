# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2212
# Title: scopes through associations chained with .order fail
# URL: https://github.com/rsim/oracle-enhanced/issues/2212
# Status: not reproduced (appears fixed upstream)
# Notes:
#   Reported against Rails 6.1.4.1 / oracle-enhanced 6.1.4 on Oracle 12c.
#   User reports: a scope that does
#     includes(:children).references(:children).merge(Child.some_scope)
#   works fine on its own (.count == 1, .first returns the Post). But
#   when `.order('posts.title')` is chained onto the relation, .count
#   still returns 1, yet .first returns nil. The attached reproduction
#   script (active_record_gem.txt on the issue) provides four tests;
#   the last one fails on the `assert_instance_of Post, r.first` line.
#
#   This spec reconstructs the same scenario: Post has_many :comments,
#   Post.for_comment_type(id) eager-loads comments via includes+references
#   then merges Comment.for_comment_type(id). With one matching post and
#   two comments (one of which matches comment_type_id=1), we then chain
#   `.order('posts.title')` and verify that `.first` still returns the
#   Post (not nil).
#
#   Result on oracle-enhanced master + ActiveRecord 8.2.0.alpha against
#   local Oracle XE: all four examples pass, including the chained
#   .order case. The bug appears resolved in current Rails -- almost
#   certainly fixed in ActiveRecord itself, since the failure mode
#   (eager-loaded relation + order + .first returning nil) is database
#   agnostic and matches several closed AR bugs from the 6.1 -> 7.x
#   timeframe around references/eager_load + ORDER BY interaction.

require "spec_helper"

RSpec.describe "Issue #2212: scopes through associations chained with .order" do
  include SchemaSpecHelper

  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    schema_define do
      create_table :test_issue_2212_posts, force: true do |t|
        t.string :title, limit: 32
      end

      create_table :test_issue_2212_comments, force: true do |t|
        t.integer :post_id
        t.integer :comment_type_id
      end
    end

    class ::TestIssue2212Post < ActiveRecord::Base
      self.table_name = "test_issue_2212_posts"
      has_many :comments,
               class_name: "TestIssue2212Comment",
               foreign_key: :post_id,
               dependent: :destroy

      scope :for_comment_type, lambda { |id|
        includes(:comments)
          .references(:comments)
          .merge(TestIssue2212Comment.for_comment_type(id))
      }
    end

    class ::TestIssue2212Comment < ActiveRecord::Base
      self.table_name = "test_issue_2212_comments"
      belongs_to :post,
                 class_name: "TestIssue2212Post",
                 foreign_key: :post_id

      scope :for_comment_type, lambda { |id|
        where(comment_type_id: id)
      }
    end
  end

  after(:all) do
    Object.send(:remove_const, "TestIssue2212Comment") if defined?(TestIssue2212Comment)
    Object.send(:remove_const, "TestIssue2212Post") if defined?(TestIssue2212Post)
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table :test_issue_2212_comments, if_exists: true
    conn.drop_table :test_issue_2212_posts, if_exists: true
    ActiveRecord::Base.clear_cache!
  end

  before(:each) do
    TestIssue2212Comment.delete_all
    TestIssue2212Post.delete_all
    post = TestIssue2212Post.create!(title: "ABC")
    post.comments.create!(comment_type_id: 1)
    post.comments.create!(comment_type_id: 2)
  end

  it "returns the post when querying by title without scope" do
    r = TestIssue2212Post.where(title: "ABC")
    expect(r).to be_a(ActiveRecord::Relation)
    expect(r.count).to eq(1)
    expect(r.first).to be_a(TestIssue2212Post)
  end

  it "returns the post when querying by title with .order chained" do
    r = TestIssue2212Post.where(title: "ABC").order("test_issue_2212_posts.title")
    expect(r).to be_a(ActiveRecord::Relation)
    expect(r.count).to eq(1)
    expect(r.first).to be_a(TestIssue2212Post)
  end

  it "returns the post via for_comment_type scope alone" do
    r = TestIssue2212Post.for_comment_type(1)
    expect(r).to be_a(ActiveRecord::Relation)
    expect(r.count).to eq(1)
    expect(r.first).to be_a(TestIssue2212Post)
  end

  it "returns the post via for_comment_type scope chained with .order [BUG]" do
    r = TestIssue2212Post.for_comment_type(1).order("test_issue_2212_posts.title")
    expect(r).to be_a(ActiveRecord::Relation)
    expect(r.count).to eq(1)
    # Per the issue, this is where it fails: r.first comes back nil.
    expect(r.first).to be_a(TestIssue2212Post)
  end
end
