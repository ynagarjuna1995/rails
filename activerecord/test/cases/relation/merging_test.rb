require 'cases/helper'
require 'models/author'
require 'models/comment'
require 'models/developer'
require 'models/post'
require 'models/project'

class RelationMergingTest < ActiveRecord::TestCase
  fixtures :developers, :comments, :authors, :posts

  def test_relation_merging
    devs = Developer.where("salary >= 80000").merge(Developer.limit(2)).merge(Developer.order('id ASC').where("id < 3"))
    assert_equal [developers(:david), developers(:jamis)], devs.to_a

    dev_with_count = Developer.limit(1).merge(Developer.order('id DESC')).merge(Developer.select('developers.*'))
    assert_equal [developers(:poor_jamis)], dev_with_count.to_a
  end

  def test_relation_to_sql
    sql = Post.connection.unprepared_statement do
      Post.first.comments.to_sql
    end
    assert_no_match(/\?/, sql)
  end

  def test_relation_merging_with_arel_equalities_keeps_last_equality
    devs = Developer.where(Developer.arel_table[:salary].eq(80000)).merge(
      Developer.where(Developer.arel_table[:salary].eq(9000))
    )
    assert_equal [developers(:poor_jamis)], devs.to_a
  end

  def test_relation_merging_with_arel_equalities_keeps_last_equality_with_non_attribute_left_hand
    salary_attr = Developer.arel_table[:salary]
    devs = Developer.where(
      Arel::Nodes::NamedFunction.new('abs', [salary_attr]).eq(80000)
    ).merge(
      Developer.where(
        Arel::Nodes::NamedFunction.new('abs', [salary_attr]).eq(9000)
      )
    )
    assert_equal [developers(:poor_jamis)], devs.to_a
  end

  def test_relation_merging_with_eager_load
    relations = []
    relations << Post.order('comments.id DESC').merge(Post.eager_load(:last_comment)).merge(Post.all)
    relations << Post.eager_load(:last_comment).merge(Post.order('comments.id DESC')).merge(Post.all)

    relations.each do |posts|
      post = posts.find { |p| p.id == 1 }
      assert_equal Post.find(1).last_comment, post.last_comment
    end
  end

  def test_relation_merging_with_locks
    devs = Developer.lock.where("salary >= 80000").order("id DESC").merge(Developer.limit(2))
    assert devs.locked.present?
  end

  def test_relation_merging_with_preload
    [Post.all.merge(Post.preload(:author)), Post.preload(:author).merge(Post.all)].each do |posts|
      assert_queries(2) { assert posts.first.author }
    end
  end

  def test_relation_merging_with_joins
    comments = Comment.joins(:post).where(:body => 'Thank you for the welcome').merge(Post.where(:body => 'Such a lovely day'))
    assert_equal 1, comments.count
  end

  def test_relation_merging_with_association
    assert_queries(2) do  # one for loading post, and another one merged query
      post = Post.where(:body => 'Such a lovely day').first
      comments = Comment.where(:body => 'Thank you for the welcome').merge(post.comments)
      assert_equal 1, comments.count
    end
  end

  test "merge collapses wheres from the LHS only" do
    left  = Post.where(title: "omg").where(comments_count: 1)
    right = Post.where(title: "wtf").where(title: "bbq")

    expected = [left.where_values[1]] + right.where_values
    merged   = left.merge(right)

    assert_equal expected, merged.where_values
    assert !merged.to_sql.include?("omg")
    assert merged.to_sql.include?("wtf")
    assert merged.to_sql.include?("bbq")
  end

  def test_merging_removes_rhs_bind_parameters
    left  = Post.where(id: Arel::Nodes::BindParam.new('?'))
    column = Post.columns_hash['id']
    left.bind_values += [[column, 20]]
    right   = Post.where(id: 10)

    merged = left.merge(right)
    assert_equal [], merged.bind_values
  end

  def test_merging_keeps_lhs_bind_parameters
    column = Post.columns_hash['id']
    binds = [[column, 20]]

    right  = Post.where(id: Arel::Nodes::BindParam.new('?'))
    right.bind_values += binds
    left   = Post.where(id: 10)

    merged = left.merge(right)
    assert_equal binds, merged.bind_values
  end

  def test_merging_reorders_bind_params
    post         = Post.first
    id_column    = Post.columns_hash['id']
    title_column = Post.columns_hash['title']

    bv = Post.connection.substitute_at id_column, 0

    right  = Post.where(id: bv)
    right.bind_values += [[id_column, post.id]]

    left   = Post.where(title: bv)
    left.bind_values += [[title_column, post.title]]

    merged = left.merge(right)
    assert_equal post, merged.first
  end
end

class MergingDifferentRelationsTest < ActiveRecord::TestCase
  fixtures :posts, :authors

  test "merging where relations" do
    hello_by_bob = Post.where(body: "hello").joins(:author).
      merge(Author.where(name: "Bob")).order("posts.id").pluck("posts.id")

    assert_equal [posts(:misc_by_bob).id,
                  posts(:other_by_bob).id], hello_by_bob
  end

  test "merging order relations" do
    posts_by_author_name = Post.limit(3).joins(:author).
      merge(Author.order(:name)).pluck("authors.name")

    assert_equal ["Bob", "Bob", "David"], posts_by_author_name
  end
end
