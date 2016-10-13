defmodule PhoenixChina.CommentController do
  use PhoenixChina.Web, :controller

  alias PhoenixChina.{User, Comment, Post, Notification}

  import PhoenixChina.ViewHelpers, only: [current_user: 1]
  import PhoenixChina.ModelOperator, only: [set: 4, inc: 3, dec: 3]

  plug Guardian.Plug.EnsureAuthenticated, [handler: PhoenixChina.GuardianErrorHandler]
    when action in [:create, :edit, :update, :delete]

  def show(conn, %{"post_id" => post_id, "id" => comment_id}) do
    post = Post
    |> preload([:user, :latest_comment, latest_comment: :user])
    |> Repo.get!(post_id)

    comment = Comment
    |> preload(:user)
    |> Repo.get!(comment_id)

    conn
    |> assign(:title, comment.user.nickname <> "在帖子" <> post.title <> "的评论")
    |> assign(:post, post)
    |> assign(:comment, comment)
    |> render("show.html")
  end

  def create(conn, %{"post_id" => post_id, "comment" => comment_params}) do
    current_user = current_user(conn)
    post = Repo.get!(Post, post_id)

    comment_params = comment_params
    |> Map.put_new("post_id", post.id)
    |> Map.put_new("user_id", current_user.id)

    changeset = Comment.changeset(%Comment{}, comment_params)

    case Repo.insert(changeset) do
      {:ok, comment} ->
        Post |> set(post, :latest_comment_id, comment.id)
        Post |> set(post, :latest_comment_inserted_at, comment.inserted_at)
        Post |> inc(post, :comment_count)

        Enum.map(Regex.scan(~r/@(\S+)\s?/, comment.content), fn [_, username] ->
          user = User |> Repo.get_by(username: username)

          if user && (user != current_user) do
            notification_html = Notification.render "at_comment.html",
              conn: conn,
              user: current_user,
              post: post,
              comment: comment


            Notification.publish(
              "at_comment",
              user.id,
              current_user.id,
              comment.id,
              notification_html
            )

            User |> inc(user, :unread_notifications_count)
          end
        end)

        if current_user.id != post.user_id do
          notification_html = Notification.render "comment.html",
            conn: conn,
            user: current_user,
            post: post,
            comment: comment

          Notification.publish(
            "comment_post",
            post.user_id,
            current_user.id,
            post.id,
            notification_html
          )

          User |> inc(%{id: post.user_id}, :unread_notifications_count)
        end

        conn |> put_flash(:info, "评论创建成功.")
      {:error, _changeset} ->
        conn |> put_flash(:error, "评论创建失败.")
    end
    |> redirect(to: post_path(conn, :show, post_id))
  end

  def edit(conn, %{"post_id" => post_id, "id" => id}) do
    current_user = current_user(conn)
    comment = Repo.get!(Comment, id)

    case comment.user_id == current_user.id do
      false ->
        conn
        |> put_flash(:info, "不是自己的评论，不允许编辑！")
        |> redirect(to: post_path(conn, :show, post_id))

      true ->
        changeset = Comment.changeset(comment)

        conn
        |> assign(:title, "编辑评论")
        |> assign(:comment, comment)
        |> assign(:changeset, changeset)
        |> render("edit.html")
    end
  end

  def update(conn, %{"post_id" => post_id, "id" => id, "comment" => comment_params}) do
    current_user = current_user(conn)
    comment = Repo.get!(Comment, id)

    case comment.user_id == current_user.id do
      false ->
        conn
        |> put_flash(:info, "不是自己的评论，不允许编辑！")
        |> redirect(to: post_path(conn, :show, post_id))

      true ->
        changeset = Comment.changeset(comment, comment_params)

        case Repo.update(changeset) do
          {:ok, _comment} ->
            conn
            |> put_flash(:info, "评论更新成功！")
            |> redirect(to: post_path(conn, :show, post_id))
          {:error, changeset} ->
            conn
            |> assign(:title, "编辑评论")
            |> assign(:comment, comment)
            |> assign(:changeset, changeset)
            |> render("edit.html")
        end
    end
  end

  def delete(conn, %{"post_id" => post_id, "id" => id}) do
    current_user = current_user(conn)
    post = Repo.get!(Post, post_id)
    comment = Repo.get!(Comment, id)

    case comment.user_id == current_user.id do
      false ->
        conn
        |> put_flash(:info, "不是自己的评论，不允许删除！")
        |> redirect(to: post_path(conn, :show, post_id))

      true ->
        latest_comment_id = Comment
        |> where([c], c.post_id == ^comment.post_id and c.id != ^comment.id)
        |> select([u], max(u.id))
        |> Repo.one

        Post |> set(post, :latest_comment_id, latest_comment_id)

        Repo.delete!(comment)

        Post |> dec(post, :comment_count)

        conn
        |> put_flash(:info, "评论删除成功！")
        |> redirect(to: post_path(conn, :show, post_id))
    end
  end
end
