# Ghi chú cấu hình GitLab local

Ngày ghi nhận: 2026-11-10. Môi trường: laptop Windows/WSL, khoảng 7,7 GiB RAM
khả dụng cho WSL. Ghi chú mô tả setup tại thời điểm này; không chứng nhận tính
tương đương với môi trường benchmark chính thức.

## Image và container

- Image nguồn: `gitlab-populated-final-port8023:latest`, đã load từ archive.
- Không build lại image, không dùng `docker commit` để lưu các chỉnh sửa thành image.
- Script `WebArena-Env-Setup/reset_gitlab.sh` tạo container `gitlab` từ image nguồn,
  sửa `/etc/gitlab/gitlab.rb` trong container rồi chạy `gitlab-ctl reconfigure`.
- Các thay đổi thuộc lớp ghi của container. Reset xóa container hiện tại, tạo lại
  từ image nguồn và áp dụng lại cấu hình local. Script từ chối reset container có
  mount dữ liệu ngoài.

## Các điều chỉnh

| Hạng mục | Giá trị local | Lý do và khác biệt |
|---|---|---|
| URL và port | `http://localhost:9001`, map `9001:9001` | Khớp task/config local. Đổi `external_url` rồi reconfigure là bước có trong hướng dẫn WebArena chính thức; hướng dẫn đó dùng port 8023. |
| Puma | `puma['worker_processes'] = 2` | Giảm RAM. Script setup sẵn trong repo này (`05_docker_patch_containers.sh`) đặt 4 worker; 2 là điều chỉnh local bổ sung, không phải yêu cầu chính thức. |
| Monitoring | `prometheus_monitoring['enable'] = false` | Tắt bộ monitoring đi kèm để giảm tài nguyên; điều chỉnh local bổ sung. |
| Shared memory | Docker `--shm-size=256m` | Cấu hình runtime bổ sung cho container. |
| Auto-login | Timeout mở trang đăng nhập và click Sign in: 120 giây thay vì mặc định 30 giây | Chờ request chậm sau khi GitLab vừa khởi động. Thay đổi ở `Eval/browser_env/auto_login.py`. |
| Preflight đăng nhập | Dùng helper đăng nhập benchmark, kiểm tra profile đã xác thực; tối đa 3 lần, nghỉ 10 giây giữa các lần lỗi | Kiểm tra website trước khi task bắt đầu. HTTP 200 ở trang Sign in chưa bảo đảm request sau đăng nhập sẵn sàng. |

Nguồn đối chiếu:

- [Hướng dẫn GitLab chính thức của WebArena](https://github.com/web-arena-x/webarena/blob/main/environment_docker/README.md#gitlab-website).
- Script có sẵn trong repo này: `WebArena-Env-Setup/05_docker_patch_containers.sh`.
  Repo setup này tự ghi rõ không phải repo WebArena chính thức.

## Dữ liệu và ảnh hưởng đến đánh giá

Không chủ động sửa nội dung project/issue, task, đáp án hoặc logic chấm điểm
để làm task dễ hơn. Các lần kiểm tra có đăng nhập tài khoản benchmark `byteblaze`;
đăng nhập có thể cập nhật session, thời điểm/IP đăng nhập và audit hoặc notification
theo hoạt động bình thường của GitLab. `gitlab-ctl reconfigure` cũng tạo/cập nhật
cấu hình và có thể thực hiện các bước bảo trì sẵn có của GitLab.

Batch mới reset GitLab trước khi chạy, rồi kiểm tra đăng nhập. Chạy tuần tự
30 task chỉ dùng GitLab trong WebArena-Lite; không reset giữa từng task. Resume
giữ container/database hiện tại và bỏ qua task đã có điểm. Không reset thủ công
trước khi resume. Đây là kết quả trên subset GitLab của WebArena-Lite, không phải
điểm toàn bộ WebArena 812 task.

Các điều chỉnh tài nguyên chủ yếu phục vụ vận hành, nhưng số worker, monitoring,
shared memory, timeout và preflight có thể ảnh hưởng độ trễ, lỗi hạ tầng hoặc trạng
thái session. Chưa có kiểm chứng tương đương trực tiếp với cấu hình gốc. Khi báo
cáo kết quả nghiên cứu, cần công bố các khác biệt này và dùng cùng cấu hình website
cho những lượt so sánh thinking/non-thinking.

Ở thời điểm ghi chú, đã kiểm tra trang Sign in trả HTTP 200 và đăng nhập vào
`/-/profile` thành công. Chưa chạy task eval GitLab trong quá trình thiết lập.
Các lần kiểm tra ban đầu gặp 502 lúc Puma nạp ứng dụng và timeout phía server
trong các request đăng nhập đầu tiên; các lần kiểm tra sau đã thành công.

## Thông tin cần giữ cho mỗi lượt chạy

Giữ thư mục kết quả với `run_config.json`, `model_endpoints.json`,
`container_state.json`, `task_ids.txt`, logs/actions và `summary.json`.
Metadata hiện tại chưa lưu đầy đủ cấu hình GitLab hay ID image bất biến; khi báo
cáo hoặc chia sẻ kết quả, lưu thêm bản script reset và image ID tương ứng. Không
chỉ dựa vào tag `latest` để xác định image giữa các máy hoặc thời điểm khác nhau.

Có thể ghi nhận image ID bằng lệnh đọc:

```bash
docker image inspect gitlab-populated-final-port8023:latest --format '{{.Id}}'
```

## Cập nhật transport LLM: streaming

Runner local hiện mặc định `LLM_STREAM=true` cho actor. Có thể tắt bằng
`LLM_STREAM=false`. Lựa chọn được lưu trong `request_policy.stream`; đổi lựa chọn
khi resume được ghi vào `resume_history.jsonl`, còn cấu hình batch ban đầu được
giữ nguyên. Các batch cũ thiếu trường này dùng non-streaming trước khi tính năng
được thêm. Judge giữ nguyên đường gọi hiện có.

Agent chờ hoàn tất stream rồi mới thực hiện action. Token budget, prompt và logic
chấm không đổi. Nếu stream bị đứt, bỏ câu trả lời dở và retry cả request. Log chỉ
ghi số ký tự reasoning/content và thời gian, không ghi nội dung reasoning riêng.
Khi so sánh kết quả, cần ghi nhận cả thay đổi transport/retry vì chúng có thể ảnh
hưởng mức độ hoàn tất request; không coi đây là bằng chứng hai lượt sinh giống nhau.

## Sửa schema task 96 (2026-11-10)

Task 96 ban đầu dùng chuỗi `"Good idea"` tại
`eval.program_html[0].required_contents.must_include`, trong khi evaluator yêu cầu
list. Đã đổi thành `["Good idea"]` để sửa `AssertionError` lúc chấm điểm. Không
đổi intent, nội dung đáp án, locator, URL tham chiếu hay logic evaluator. Quét
165 task Lite không thấy trường `program_html` `must_include`/`must_exclude` nào
khác sai kiểu list. Đây là chỉnh sửa dataset local cần công bố khi báo cáo.

Không tự sửa điểm cũ, reset website hoặc chạy lại eval. Có thể resume batch để
chạy lại task 96; trạng thái website do các lần thử trước tạo ra vẫn được giữ.
