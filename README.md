Play the classic game WITH your friends! Place blocks and clear lines on a single board. Keeps the classic pieces and movement with a unique multiplayer mechanic. Work together to reach the top of the leaderboard. 

# Where to play

- **Web:** https://nuclearquads.com/tandora/ (also https://nuclearquads.github.io/tandora/)
  - Built and deployed automatically by CI on every push to `master` (Godot Web export → GitHub Pages `tandora/` folder). The deployed `index.html` carries a `<!-- build: <sha> -->` marker so you can confirm which commit is live.
  - The web client connects to the hosted server automatically; no setup needed.
- **Desktop/iOS:** see the `latest` GitHub release (auto-published from `master` by CI).

Features:
- 1-8 players
- Multiple local players per device (keyboards + controllers)
- Controller support
- Custom host usernames on the leaderboards
- Leader reassignment when the host leaves a lobby
- Native iOS, tvOS, Android, and universal web versions
- Different leaderboard for each player count

# Debugging Setup

- Enable Multiple Instances: 3
- Check all overrides
- Launch Arguments:
  - --headless --display-driver headless
  - --position 0,500 --instance_id=1
  - --position 0,640 --instance_id=2
- Feature Tags:
  - local
  - local
  - local
